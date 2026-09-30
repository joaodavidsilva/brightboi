import AppKit
import CoreGraphics

/// Watches for another app swallowing the brightness keys BrightBoi claims.
/// It installs a listen-only tap at the HID level, which sees a key press
/// before any session tap, and compares what it saw with what BrightBoi's own
/// session tap received (see `KeyInterceptionMonitor`). A press seen at the
/// HID level but never delivered to BrightBoi was consumed by another tap.
///
/// Best effort. A listen-only tap needs the Input Monitoring permission, so
/// the detector only starts when that is already granted and never asks for
/// it; without it, no conflict is ever reported.
@MainActor
final class KeyInterceptionDetector {
    /// How long BrightBoi's own tap gets to receive a press the HID-level tap
    /// already saw, before it counts as swallowed.
    private static let confirmationDelay: TimeInterval = 0.2

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var plan: KeyTapPlan?
    private var monitor = KeyInterceptionMonitor()
    private var isOwnTapEnabled: () -> Bool = { false }
    private var onInterception: () -> Void = {}

    isolated deinit {
        stop()
    }

    var isRunning: Bool { tap != nil }

    /// Starts watching for presses matching `plan`'s media keys.
    /// `isOwnTapEnabled` guards against blaming another app while BrightBoi's
    /// own tap is switched off; `onInterception` runs when a press was swallowed.
    func start(plan: KeyTapPlan, isOwnTapEnabled: @escaping () -> Bool, onInterception: @escaping () -> Void) {
        self.plan = plan
        self.isOwnTapEnabled = isOwnTapEnabled
        self.onInterception = onInterception
        guard tap == nil, CGPreflightListenEventAccess() else { return }

        guard let created = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << NSEvent.EventType.systemDefined.rawValue),
            callback: { _, _, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let detector = Unmanaged<KeyInterceptionDetector>.fromOpaque(refcon).takeUnretainedValue()
                let timestamp = cgEvent.timestamp
                let flags = cgEvent.flags
                let nsEvent = NSEvent(cgEvent: cgEvent)
                let subtype = nsEvent?.subtype.rawValue ?? 0
                let data1 = nsEvent?.data1 ?? 0
                // The run-loop source is on the main run loop.
                MainActor.assumeIsolated {
                    detector.observe(timestamp: timestamp, subtype: subtype, data1: data1, flags: flags)
                }
                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.keyTap.notice("Could not start watching for other apps taking the brightness keys")
            return
        }

        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        plan = nil
        monitor = KeyInterceptionMonitor()
    }

    /// BrightBoi's own tap received a press it claims.
    func noteReceivedByTap(timestamp: UInt64) {
        monitor.receivedByTap(timestamp: timestamp)
    }

    private func observe(timestamp: UInt64, subtype: Int16, data1: Int, flags: CGEventFlags) {
        guard let plan,
              KeyTapMatcher.mediaKeyPress(subtype: subtype, data1: data1, flags: flags, plan: plan) != nil else { return }

        monitor.observedAtHID(timestamp: timestamp)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmationDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.confirm(timestamp: timestamp)
            }
        }
    }

    private func confirm(timestamp: UInt64) {
        guard monitor.wasIntercepted(timestamp: timestamp), isOwnTapEnabled() else { return }
        onInterception()
    }

    /// The taps currently installed in the session, for naming the culprit.
    static func installedTaps() -> [EventTapSnapshot] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
        return list.prefix(Int(count)).map {
            EventTapSnapshot(
                processID: $0.tappingProcess,
                isActiveFilter: $0.options == .defaultTap,
                isEnabled: $0.enabled,
                eventsOfInterest: $0.eventsOfInterest
            )
        }
    }
}
