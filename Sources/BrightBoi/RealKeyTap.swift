import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

/// Real `KeyTapControlling`: a session-level `CGEventTap` that intercepts the
/// physical F1/F2 brightness keys system-wide, in both the forms a Mac
/// keyboard can send them —
///
/// - Pressed alone, they arrive as `NX_SYSDEFINED` events (macOS's own
///   "media key" mechanism), not ordinary key events.
/// - Held with Fn, they arrive as ordinary `keyDown` events at the F1/F2
///   virtual keycodes, since Fn inverts the keyboard's default media-key
///   behavior.
///
/// Registered with `.defaultTap` (not `.listenOnly`) and returns `nil` for
/// every brightness key event it recognizes, which is what actually
/// supersedes macOS's native handling — a listen-only tap would still let
/// the OS apply its own Nominal-range adjustment underneath BrightBoi's.
final class RealKeyTap: KeyTapControlling {
    // Standard virtual keycodes for the F1/F2 function keys (Carbon
    // HIToolbox constants `kVK_F1`/`kVK_F2` — stable across macOS versions,
    // reproduced here to avoid pulling in all of Carbon for two constants).
    private static let virtualKeyCodeF1: Int64 = 0x7A
    private static let virtualKeyCodeF2: Int64 = 0x78

    // `NX_KEYTYPE_BRIGHTNESS_UP`/`NX_KEYTYPE_BRIGHTNESS_DOWN` from
    // `IOKit/hidsystem/ev_keymap.h` — the media-key type codes packed into
    // an `NX_SYSDEFINED` event's `data1` field.
    private static let brightnessUpKeyCode: Int32 = 2
    private static let brightnessDownKeyCode: Int32 = 3

    // The `NX_SYSDEFINED` "keyState" nibble that means key-down. This
    // data1 bit layout is undocumented by Apple but a long-stable
    // reverse-engineered convention (used by e.g. MediaKeyTap, Karabiner).
    private static let keyDownState: Int64 = 0x0A

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onKeyPress: ((BrightnessController.KeyPress) -> Void)?

    func startIntercepting(onKeyPress: @escaping (BrightnessController.KeyPress) -> Void) {
        self.onKeyPress = onKeyPress
        requestPermissionsIfNeeded()
        installEventTap()
    }

    // MARK: - Permissions

    /// Both Input Monitoring (raw HID/media-key event access) and
    /// Accessibility (needed for a tap that can consume, not just observe,
    /// key events) gate this feature per the spec's Further Notes. Each is
    /// only ever unrequested once — after the user answers macOS's system
    /// prompt, `AXIsProcessTrusted`/`IOHIDCheckAccess` reflect that answer on
    /// every future launch, so this explanation alert naturally shows only
    /// on first run.
    private func requestPermissionsIfNeeded() {
        let needsAccessibility = !AXIsProcessTrusted()
        let needsInputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted

        guard needsAccessibility || needsInputMonitoring else { return }

        presentPermissionExplanationAlert()

        if needsAccessibility {
            // Referenced by its raw key name rather than the
            // `kAXTrustedCheckOptionPrompt` global: that `Unmanaged<CFString>`
            // constant fails Swift 6 strict-concurrency checking as
            // shared mutable global state, and the key name itself is a
            // stable, documented part of the `AXIsProcessTrustedWithOptions` API.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if needsInputMonitoring {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    private func presentPermissionExplanationAlert() {
        let alert = NSAlert()
        alert.messageText = "BrightBoi needs Accessibility and Input Monitoring access"
        alert.informativeText = """
        BrightBoi remaps the physical F1/F2 brightness keys to control its full \
        0–200% range instead of macOS's default 0–100% range. To intercept \
        those key presses system-wide, macOS requires Accessibility and Input \
        Monitoring permission, which you'll be asked to grant next.
        """
        alert.addButton(withTitle: "Continue")
        alert.runModal()
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

        if let press = brightnessMediaKeyPress(from: type, cgEvent: cgEvent) {
            onKeyPress?(press)
            return nil
        }

        if let press = fnBrightnessKeyPress(from: type, cgEvent: cgEvent) {
            onKeyPress?(press)
            return nil
        }

        return Unmanaged.passUnretained(cgEvent)
    }

    private func brightnessMediaKeyPress(from type: CGEventType, cgEvent: CGEvent) -> BrightnessController.KeyPress? {
        guard type.rawValue == NSEvent.EventType.systemDefined.rawValue,
              let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.subtype.rawValue == 8 else { return nil }

        let keyCode = Int32((nsEvent.data1 & 0xFFFF0000) >> 16)
        let keyState = (nsEvent.data1 & 0xFF00) >> 8
        guard keyState == Self.keyDownState else { return nil }

        switch keyCode {
        case Self.brightnessUpKeyCode: return .raise
        case Self.brightnessDownKeyCode: return .lower
        default: return nil
        }
    }

    private func fnBrightnessKeyPress(from type: CGEventType, cgEvent: CGEvent) -> BrightnessController.KeyPress? {
        guard type == .keyDown else { return nil }

        switch cgEvent.getIntegerValueField(.keyboardEventKeycode) {
        case Self.virtualKeyCodeF1: return .lower
        case Self.virtualKeyCodeF2: return .raise
        default: return nil
        }
    }
}
