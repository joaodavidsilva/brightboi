import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

/// Real `KeyTapControlling`: a session-level `CGEventTap` that intercepts the
/// configured Key Remap combo system-wide. The default F1/F2 combo arrives in
/// two different forms a Mac keyboard can send it —
///
/// - Pressed alone, they arrive as `NX_SYSDEFINED` events (macOS's own
///   "media key" mechanism), not ordinary key events.
/// - Held with Fn, they arrive as ordinary `keyDown` events at the F1/F2
///   virtual keycodes, since Fn inverts the keyboard's default media-key
///   behavior.
///
/// Any other configured combo (which per ADR-0007 always carries at least
/// one modifier) only ever arrives as an ordinary `keyDown` event with
/// matching modifier flags — it has no media-key form.
///
/// Registered with `.defaultTap` (not `.listenOnly`) and returns `nil` for
/// every recognized combo, which is what actually supersedes macOS's native
/// handling — a listen-only tap would still let the OS apply its own
/// Nominal-range adjustment underneath BrightBoi's.
final class RealKeyTap: KeyTapControlling {
    // `NX_KEYTYPE_BRIGHTNESS_UP`/`NX_KEYTYPE_BRIGHTNESS_DOWN` from
    // `IOKit/hidsystem/ev_keymap.h` — the media-key type codes packed into
    // an `NX_SYSDEFINED` event's `data1` field.
    private static let brightnessUpKeyCode: Int32 = 2
    private static let brightnessDownKeyCode: Int32 = 3

    // The `NX_SYSDEFINED` "keyState" nibble that means key-down, and the
    // `data1` bit layout it's packed into (top 16 bits: key code, next byte:
    // state). Both are undocumented by Apple but a long-stable
    // reverse-engineered convention (used by e.g. MediaKeyTap, Karabiner).
    private static let keyDownState: Int = 0x0A
    private static let keyCodeMask: Int = 0xFFFF0000
    private static let keyCodeShift: Int = 16
    private static let keyStateMask: Int = 0xFF00
    private static let keyStateShift: Int = 8

    // `NX_SUBTYPE_AUX_CONTROL_BUTTONS` — the `NSEvent.subtype` that marks a
    // `systemDefined` event as a media-key event (brightness/volume/etc.)
    // rather than some other system-defined event.
    private static let auxControlButtonsSubtype: Int16 = 8

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var remap: KeyRemapShortcut?
    private var onKeyPress: ((BrightnessController.KeyPress) -> Void)?

    func start(remap: KeyRemapShortcut, onKeyPress: @escaping (BrightnessController.KeyPress) -> Void) {
        self.remap = remap
        self.onKeyPress = onKeyPress

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            installEventTap()
        }
    }

    func stop() {
        remap = nil
        onKeyPress = nil

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event tap

    private func installEventTap() {
        let eventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << NSEvent.EventType.systemDefined.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let keyTap = Unmanaged<RealKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return keyTap.handle(type: type, cgEvent: cgEvent)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            FileHandle.standardError.write(Data(
                "BrightBoi: could not create key event tap (Accessibility/Input Monitoring permission likely not granted yet)\n".utf8
            ))
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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

        guard let remap else { return Unmanaged.passUnretained(cgEvent) }

        let press = mediaKeyPress(from: type, cgEvent: cgEvent, remap: remap)
            ?? f1f2FnKeyPress(from: type, cgEvent: cgEvent, remap: remap)
            ?? modifiedKeyPress(from: type, cgEvent: cgEvent, remap: remap)

        guard let press else { return Unmanaged.passUnretained(cgEvent) }
        onKeyPress?(press)
        return nil
    }

    /// The bare-F1/F2 media-key path — only fires for whichever direction is
    /// still configured to its default combo, so reconfiguring one direction
    /// away from F1/F2 returns the physical key to native macOS handling.
    private func mediaKeyPress(from type: CGEventType, cgEvent: CGEvent, remap: KeyRemapShortcut) -> BrightnessController.KeyPress? {
        guard type.rawValue == NSEvent.EventType.systemDefined.rawValue,
              let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.subtype.rawValue == Self.auxControlButtonsSubtype else { return nil }

        let keyCode = Int32((nsEvent.data1 & Self.keyCodeMask) >> Self.keyCodeShift)
        let keyState = (nsEvent.data1 & Self.keyStateMask) >> Self.keyStateShift
        guard keyState == Self.keyDownState else { return nil }

        switch keyCode {
        case Self.brightnessUpKeyCode where remap.raise == .f2: return .raise
        case Self.brightnessDownKeyCode where remap.lower == .f1: return .lower
        default: return nil
        }
    }

    /// The Fn+F1/F2 ordinary-`keyDown` path — same default-only gating as
    /// the media-key path above.
    private func f1f2FnKeyPress(from type: CGEventType, cgEvent: CGEvent, remap: KeyRemapShortcut) -> BrightnessController.KeyPress? {
        guard type == .keyDown else { return nil }

        switch cgEvent.getIntegerValueField(.keyboardEventKeycode) {
        case KeyCombo.f1VirtualKeyCode where remap.lower == .f1: return .lower
        case KeyCombo.f2VirtualKeyCode where remap.raise == .f2: return .raise
        default: return nil
        }
    }

    /// The general path for any reconfigured combo — always carries at
    /// least one modifier per ADR-0007, so it only ever arrives as an
    /// ordinary `keyDown`, never a media-key event. Bridges through
    /// `NSEvent` (the same bridge the media-key path above already uses) so
    /// modifier-flag interpretation has one source of truth, shared with the
    /// Settings shortcut recorder — see `KeyCombo.Modifiers.init(nsEventModifierFlags:)`.
    private func modifiedKeyPress(from type: CGEventType, cgEvent: CGEvent, remap: KeyRemapShortcut) -> BrightnessController.KeyPress? {
        guard type == .keyDown, let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }

        let combo = KeyCombo(
            modifiers: KeyCombo.Modifiers(nsEventModifierFlags: nsEvent.modifierFlags),
            keyCode: Int64(nsEvent.keyCode)
        )

        if combo == remap.raise, remap.raise != .f1, remap.raise != .f2 { return .raise }
        if combo == remap.lower, remap.lower != .f1, remap.lower != .f2 { return .lower }
        return nil
    }
}
