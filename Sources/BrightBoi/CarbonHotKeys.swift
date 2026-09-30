import AppKit
import Carbon.HIToolbox

/// Registers the custom brightness combos as system hot keys. Unlike an
/// event tap, a hot key is still delivered while Secure Keyboard Entry hides
/// ordinary key events from every tap (a focused password field, Terminal's
/// Secure Keyboard Entry, a password manager), it consumes the key so the
/// focused app never sees it, and it needs no permission.
///
/// macOS delivers a hot key once per physical press, without auto-repeat, so
/// holding a combo is reproduced with a timer that follows the system
/// key-repeat delay and rate.
@MainActor
final class CarbonHotKeys {
    /// Four-character code 'BrBi' that tags this app's hot keys.
    private static let signature: OSType = 0x4272_4269

    /// Never step faster than this, whatever the system key-repeat rate is.
    private static let minimumRepeatInterval: TimeInterval = KeyRepeatLimiter.defaultMinimumInterval

    /// A held key stops repeating after this long even without a release.
    private static let maximumHoldDuration: TimeInterval = 15

    private struct Registration {
        let ref: EventHotKeyRef
        let press: BrightnessController.KeyPress
        let keyCode: CGKeyCode
        var pressedAt = Date()
    }

    private var registrations: [UInt32: Registration] = [:]
    private var repeatTimers: [UInt32: Timer] = [:]
    private var handlerRef: EventHandlerRef?
    private var onPress: ((BrightnessController.KeyPress) -> Void)?

    isolated deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    /// Replaces every registered hot key with `hotKeys`. Returns the ones
    /// macOS refused, so the caller can fall back to another way of seeing them.
    func register(
        _ hotKeys: [(press: BrightnessController.KeyPress, combo: KeyCombo)],
        onPress: @escaping (BrightnessController.KeyPress) -> Void
    ) -> [(press: BrightnessController.KeyPress, combo: KeyCombo)] {
        unregisterAll()
        self.onPress = onPress
        guard !hotKeys.isEmpty, installHandlerIfNeeded() else { return hotKeys }

        var failed: [(press: BrightnessController.KeyPress, combo: KeyCombo)] = []
        for (index, hotKey) in hotKeys.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(hotKey.combo.keyCode),
                hotKey.combo.modifiers.carbonModifiers,
                EventHotKeyID(signature: Self.signature, id: id),
                GetEventDispatcherTarget(),
                OptionBits(kEventHotKeyExclusive),
                &ref
            )
            if status == noErr, let ref {
                registrations[id] = Registration(ref: ref, press: hotKey.press, keyCode: CGKeyCode(hotKey.combo.keyCode))
            } else {
                Log.keyTap.error("Could not register \(hotKey.combo.displayString, privacy: .public) as a hot key (status \(status, privacy: .public)); falling back to the event tap")
                failed.append(hotKey)
            }
        }
        return failed
    }

    func unregisterAll() {
        for timer in repeatTimers.values { timer.invalidate() }
        repeatTimers.removeAll()
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    // MARK: - Events

    private func installHandlerIfNeeded() -> Bool {
        guard handlerRef == nil else { return true }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard parameterStatus == noErr, hotKeyID.signature == CarbonHotKeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let isPressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let hotKeys = Unmanaged<CarbonHotKeys>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers application events on the main thread.
                MainActor.assumeIsolated {
                    hotKeys.handle(id: hotKeyID.id, isPressed: isPressed)
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != noErr {
            Log.keyTap.error("Could not install the hot key handler (status \(status, privacy: .public))")
            handlerRef = nil
        }
        return status == noErr
    }

    private func handle(id: UInt32, isPressed: Bool) {
        guard let registration = registrations[id] else { return }

        if !isPressed {
            stopRepeating(id: id)
            return
        }
        // A second press while this key is already repeating is a stray;
        // the release that ends the repeat has not arrived yet.
        guard repeatTimers[id] == nil else { return }

        registrations[id]?.pressedAt = Date()
        onPress?(registration.press)
        scheduleFirstRepeat(id: id)
    }

    private func scheduleFirstRepeat(id: UInt32) {
        let first = Timer(timeInterval: NSEvent.keyRepeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beginRepeating(id: id)
            }
        }
        RunLoop.main.add(first, forMode: .common)
        repeatTimers[id] = first
    }

    private func beginRepeating(id: UInt32) {
        guard repeatTimers[id] != nil, registrations[id] != nil else { return }
        let interval = max(NSEvent.keyRepeatInterval, Self.minimumRepeatInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTick(id: id)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimers[id] = timer
        repeatTick(id: id)
    }

    private func repeatTick(id: UInt32) {
        guard let registration = registrations[id] else {
            stopRepeating(id: id)
            return
        }
        // Safety net: if the release was never delivered, stop once the key
        // is physically up, or after a hard cap, instead of repeating forever.
        // Under Secure Keyboard Entry the key state reads as up even while the
        // key is held, so there only the release and the cap end the repeat.
        let isHeld = IsSecureEventInputEnabled()
            || CGEventSource.keyState(.combinedSessionState, key: registration.keyCode)
        let isWithinCap = registration.pressedAt.distance(to: Date()) < Self.maximumHoldDuration
        guard isHeld, isWithinCap else {
            stopRepeating(id: id)
            return
        }
        onPress?(registration.press)
    }

    private func stopRepeating(id: UInt32) {
        repeatTimers.removeValue(forKey: id)?.invalidate()
    }
}
