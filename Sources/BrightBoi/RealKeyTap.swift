import AppKit
import CoreGraphics
import Foundation

/// Real `KeyTapControlling`. The configured Key Remap reaches BrightBoi two
/// ways, chosen per direction by `KeyTapPlan`:
///
/// - The bare F1/F2 keys arrive as `NX_SYSDEFINED` media-key events (macOS's
///   own mechanism), in both keyboard modes: Fn+F1/F2 in
///   standard-function-key mode is the same media event. They are read as the
///   combos F1 (brightness down) and F2 (brightness up), so either direction
///   can be given either key. They are caught by a session-level
///   `CGEventTap`, which needs the Accessibility permission.
///   F1 and F2 pressed as ordinary function keys are never touched, so they
///   keep working in other apps.
/// - Any other combo is registered as a system hot key (`CarbonHotKeys`),
///   which keeps working under Secure Keyboard Entry and needs no
///   permission. Only if macOS refuses a registration does the tap also
///   watch ordinary key-down events for that combo.
///
/// The tap is registered with `.defaultTap` (not `.listenOnly`) and returns
/// `nil` for every press BrightBoi takes, which is what actually supersedes
/// macOS's native handling; a listen-only tap would still let the OS apply
/// its own Nominal-range adjustment underneath BrightBoi's. When BrightBoi
/// declines a press (its display is off, for instance) the event goes through
/// untouched and macOS handles the key. Presses carrying Command, Control or
/// Option alone also pass through, since macOS gives those their own
/// meanings (external display brightness, Displays settings, mirroring).
///
/// The tap's event mask holds only what the current remap needs, so in the
/// default setup no ordinary key event ever reaches BrightBoi, and a remap
/// made only of custom combos installs no tap at all.
///
/// While the Settings recorder is armed the tap is in capture mode: the hot
/// keys are released so a combo already in use reaches the recorder, the tap
/// listens to media keys and key-downs whether or not Key Remap is on, and the
/// next key press is handed to the recorder instead of being acted on.
///
/// `@MainActor`: satisfies `KeyTapControlling`'s isolation, and lets
/// `deinit` stop everything synchronously. The tap callback itself is a plain
/// C function pointer with no isolation the compiler can see; it always
/// actually runs on the main run loop (the source is added to
/// `CFRunLoopGetMain()`), so it reaches back in via `MainActor.assumeIsolated`.
@MainActor
final class RealKeyTap: KeyTapControlling {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The mask the installed tap was created with.
    private var installedMask: CGEventMask = 0

    private var plan: KeyTapPlan?
    /// Custom combos macOS refused as hot keys, matched on key-down instead.
    private var keyDownFallback: [(press: BrightnessController.KeyPress, combo: KeyCombo)] = []
    private var onKeyPress: ((BrightnessController.KeyPress) -> Bool)?
    private var repeatLimiter = KeyRepeatLimiter()

    /// Whether the recorder has asked for capture mode, until `endCapture`.
    private var isCapturing = false
    /// Takes the next captured combo; cleared once it has been delivered.
    private var captureHandler: ((KeyCombo) -> Void)?
    /// Set once a combo has been handed over, so the auto-repeats of the held
    /// key keep being swallowed until the recorder ends the capture.
    private var captureDelivered = false

    private let hotKeys = CarbonHotKeys()
    private let interceptionDetector = KeyInterceptionDetector()
    private(set) var conflict: KeyTapConflict?
    private var conflictObservers: [() -> Void] = []

    /// Stops everything if it is still running when the object goes away:
    /// belt-and-suspenders alongside `stop()`'s explicit call sites, for
    /// whichever future refactor releases a `RealKeyTap` without calling it
    /// first. `isolated` since `stop()` is main-actor-isolated.
    isolated deinit {
        stop()
    }

    func observeConflicts(_ onChange: @escaping () -> Void) {
        conflictObservers.append(onChange)
    }

    var isActive: Bool {
        guard plan != nil else { return false }
        let needed = requiredMask
        guard needed != 0 else { return true }
        guard let eventTap, CGEvent.tapIsEnabled(tap: eventTap) else { return false }
        // The system silently clears mask bits the process may not see, and
        // still returns a tap if any bit survives; count that as not working.
        return Self.effectiveMask().map { $0 & needed == needed } ?? true
    }

    func start(remap: KeyRemapShortcut, onKeyPress: @escaping (BrightnessController.KeyPress) -> Bool) {
        self.plan = KeyTapPlan(remap: remap)
        self.onKeyPress = onKeyPress
        applyPlan()
        if !isActive {
            Log.keyTap.error("The key tap is not active (Accessibility permission likely not granted yet)")
        }
    }

    func stop() {
        plan = nil
        onKeyPress = nil
        applyPlan()
    }

    /// Makes the hot keys, the tap and the conflict detector match the current
    /// plan, or nothing when there is none. The hot keys stay released while
    /// the recorder is capturing.
    private func applyPlan() {
        if let plan, !isCapturing {
            keyDownFallback = hotKeys.register(plan.hotKeys) { [weak self] press in
                self?.deliverHotKeyPress(press)
            }
        } else {
            keyDownFallback = []
            hotKeys.unregisterAll()
        }
        reconcileTap()
        if plan != nil {
            reconcileInterceptionDetector()
        } else {
            interceptionDetector.stop()
            setConflict(nil)
        }
    }

    // MARK: - Capture

    func beginCapture(_ onCapture: @escaping (KeyCombo) -> Void) {
        isCapturing = true
        captureDelivered = false
        captureHandler = onCapture
        applyPlan()
    }

    func endCapture() {
        guard isCapturing else { return }
        isCapturing = false
        captureDelivered = false
        captureHandler = nil
        applyPlan()
    }

    // MARK: - Event tap

    /// The events the tap must see for the current remap: media keys when a
    /// direction is on its default, key-downs only for a combo macOS would not
    /// register as a hot key.
    private var requiredMask: CGEventMask {
        var mask: CGEventMask = 0
        if plan?.usesMediaKeys == true || isCapturing {
            mask |= 1 << CGEventMask(NSEvent.EventType.systemDefined.rawValue)
        }
        if !keyDownFallback.isEmpty || isCapturing {
            mask |= 1 << CGEventMask(CGEventType.keyDown.rawValue)
        }
        return mask
    }

    /// Makes the installed tap match `requiredMask`: removes it when nothing
    /// needs it, re-enables it when the mask still fits, and otherwise
    /// recreates it (a tap's mask is fixed at creation).
    private func reconcileTap() {
        let needed = requiredMask
        guard needed != 0 else {
            removeTap()
            return
        }
        if let eventTap, installedMask == needed {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }
        removeTap()
        installTap(mask: needed)
    }

    private func installTap(mask: CGEventMask) {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let keyTap = Unmanaged<RealKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                // The callback is a bare C function pointer with no isolation
                // the compiler can verify, but `installTap` only ever adds
                // this tap's run-loop source to the main run loop, so it
                // genuinely always runs there. Assigned through a `var`
                // rather than returned directly from `assumeIsolated`'s
                // closure, since its result type must be `Sendable` and
                // `CGEvent` isn't.
                var result: Unmanaged<CGEvent>?
                MainActor.assumeIsolated {
                    result = keyTap.handle(type: type, cgEvent: cgEvent)
                }
                return result
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.keyTap.error("Could not create the key event tap")
            return
        }

        eventTap = tap
        installedMask = mask
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let effective = Self.effectiveMask()
        Log.keyTap.info("Installed the key tap: requested mask \(mask, privacy: .public), effective mask \(effective ?? 0, privacy: .public)")
    }

    /// Releases the tap, invalidating its mach port so an off/on cycle does
    /// not leave a disabled tap registered with the window server.
    private func removeTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
        installedMask = 0
    }

    /// The mask the window server actually holds for this process's active
    /// tap, or `nil` when it cannot be read.
    private static func effectiveMask() -> CGEventMask? {
        KeyInterceptionDetector.installedTaps().first { snapshot in
            snapshot.processID == getpid() && snapshot.isActiveFilter
        }.map { CGEventMask($0.eventsOfInterest) }
    }

    private func handle(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long to respond (or on user
        // request via the Accessibility Inspector); re-enabling it is the
        // documented recovery so a slow moment doesn't permanently kill the
        // remap for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        if isCapturing {
            return handleCapture(type: type, cgEvent: cgEvent)
        }

        guard let plan, let onKeyPress else { return Unmanaged.passUnretained(cgEvent) }

        let press: BrightnessController.KeyPress?
        var isRepeat = false
        if type.rawValue == NSEvent.EventType.systemDefined.rawValue {
            guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return Unmanaged.passUnretained(cgEvent) }
            press = KeyTapMatcher.mediaKeyPress(
                subtype: nsEvent.subtype.rawValue,
                data1: nsEvent.data1,
                flags: cgEvent.flags,
                plan: plan
            )
            isRepeat = KeyTapMatcher.isMediaKeyRepeat(data1: nsEvent.data1)
            if press != nil {
                interceptionDetector.noteReceivedByTap(timestamp: cgEvent.timestamp)
                setConflict(nil)
            }
        } else if type == .keyDown {
            press = KeyTapMatcher.keyDownPress(
                keyCode: cgEvent.getIntegerValueField(.keyboardEventKeycode),
                flags: cgEvent.flags,
                fallback: keyDownFallback
            )
            isRepeat = cgEvent.getIntegerValueField(.keyboardEventAutorepeat) != 0
        } else {
            press = nil
        }

        guard let press else { return Unmanaged.passUnretained(cgEvent) }

        // A held key repeats at the system rate, which can be far faster than
        // a brightness step is worth; swallow the repeats that come too soon.
        let now = CACurrentMediaTime()
        if repeatLimiter.isThrottled(isRepeat: isRepeat, at: now) { return nil }

        // Swallowed only when BrightBoi took the press; otherwise macOS gets
        // the key exactly as it was sent.
        guard onKeyPress(press) else { return Unmanaged.passUnretained(cgEvent) }
        repeatLimiter.recordApplied(at: now)
        return nil
    }

    /// While capturing, the next media key or key-down becomes the recorded
    /// combo and is swallowed, so it neither steps the brightness nor reaches
    /// another app. Escape, Tab and anything typed while another app is in
    /// front pass through untouched.
    private func handleCapture(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        guard NSApp.isActive else { return Unmanaged.passUnretained(cgEvent) }
        guard let handler = captureHandler else {
            // The combo is already taken: swallow the held key's repeats too.
            guard captureDelivered, type == .keyDown || type.rawValue == NSEvent.EventType.systemDefined.rawValue else {
                return Unmanaged.passUnretained(cgEvent)
            }
            if type == .keyDown { return nil }
            if let nsEvent = NSEvent(cgEvent: cgEvent),
               KeyTapMatcher.mediaKeyCombo(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1, flags: cgEvent.flags) != nil {
                return nil
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        let combo: KeyCombo?
        if type.rawValue == NSEvent.EventType.systemDefined.rawValue {
            guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return Unmanaged.passUnretained(cgEvent) }
            combo = KeyTapMatcher.mediaKeyCombo(subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1, flags: cgEvent.flags)
            if combo != nil {
                interceptionDetector.noteReceivedByTap(timestamp: cgEvent.timestamp)
            }
        } else if type == .keyDown {
            combo = KeyTapMatcher.capturedCombo(
                keyCode: cgEvent.getIntegerValueField(.keyboardEventKeycode),
                flags: cgEvent.flags
            )
        } else {
            combo = nil
        }
        guard let combo else { return Unmanaged.passUnretained(cgEvent) }

        // One combo per capture. Handed over on the next turn of the run loop,
        // because the recorder ends the capture, which removes this tap.
        captureHandler = nil
        captureDelivered = true
        Task { @MainActor in handler(combo) }
        return nil
    }

    // MARK: - Hot keys

    private func deliverHotKeyPress(_ press: BrightnessController.KeyPress) {
        _ = onKeyPress?(press)
    }

    // MARK: - Conflict detection

    /// Watches for another app swallowing the brightness media keys, while
    /// BrightBoi's own tap is installed and listens to them.
    private func reconcileInterceptionDetector() {
        guard let plan, plan.usesMediaKeys, eventTap != nil else {
            interceptionDetector.stop()
            setConflict(nil)
            return
        }
        interceptionDetector.start(
            plan: plan,
            isOwnTapEnabled: { [weak self] in
                guard let tap = self?.eventTap else { return false }
                return CGEvent.tapIsEnabled(tap: tap)
            },
            onInterception: { [weak self] in
                self?.reportInterception()
            }
        )
    }

    private func reportInterception() {
        let taps = KeyInterceptionDetector.installedTaps()
        let pid = KeyTapConflictResolver.namedProcessID(in: taps, ownProcessID: getpid()) {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }
        let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        Log.keyTap.notice("A brightness key press never reached BrightBoi's tap; another app intercepted it (\(name ?? "unknown", privacy: .public))")
        setConflict(KeyTapConflict(appName: name))
    }

    private func setConflict(_ newValue: KeyTapConflict?) {
        guard conflict != newValue else { return }
        conflict = newValue
        for observer in conflictObservers { observer() }
    }
}
