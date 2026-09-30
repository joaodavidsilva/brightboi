import CoreGraphics
import Foundation

/// How a `KeyRemapShortcut` reaches BrightBoi. The bare F1/F2 keys only ever
/// arrive as `NX_SYSDEFINED` media-key events, which need an event tap (and so
/// the Accessibility permission). Any other combo is registered as a system
/// hot key, which macOS delivers even while Secure Keyboard Entry hides
/// ordinary key events from every tap, and which needs no permission at all.
struct KeyTapPlan: Equatable {
    /// The Raise direction is still on its default, the brightness-up media key.
    let raiseMediaKey: Bool
    /// The Lower direction is still on its default, the brightness-down media key.
    let lowerMediaKey: Bool
    /// A combo for the Raise direction that is neither F1 nor F2.
    let raiseHotKey: KeyCombo?
    /// A combo for the Lower direction that is neither F1 nor F2, and differs
    /// from the Raise combo (a hot key can be registered only once).
    let lowerHotKey: KeyCombo?

    init(remap: KeyRemapShortcut) {
        raiseMediaKey = remap.raise == .f2
        lowerMediaKey = remap.lower == .f1
        raiseHotKey = Self.isCustom(remap.raise) ? remap.raise : nil
        lowerHotKey = Self.isCustom(remap.lower) && remap.lower != remap.raise ? remap.lower : nil
    }

    /// Whether any direction listens to the brightness media keys.
    var usesMediaKeys: Bool { raiseMediaKey || lowerMediaKey }

    /// The custom combos to register, each with the press it triggers.
    var hotKeys: [(press: BrightnessController.KeyPress, combo: KeyCombo)] {
        var result: [(press: BrightnessController.KeyPress, combo: KeyCombo)] = []
        if let raiseHotKey { result.append((.raise, raiseHotKey)) }
        if let lowerHotKey { result.append((.lower, lowerHotKey)) }
        return result
    }

    private static func isCustom(_ combo: KeyCombo) -> Bool {
        combo != .f1 && combo != .f2
    }
}

/// The pure decisions behind the key tap, free of any live event so they can
/// be exercised directly. Safe to call from any thread.
enum KeyTapMatcher {
    // `NX_KEYTYPE_BRIGHTNESS_UP`/`NX_KEYTYPE_BRIGHTNESS_DOWN` from
    // `IOKit/hidsystem/ev_keymap.h`: the media-key type codes packed into an
    // `NX_SYSDEFINED` event's `data1` field.
    static let brightnessUpKeyCode: Int32 = 2
    static let brightnessDownKeyCode: Int32 = 3

    // The `NX_SYSDEFINED` "keyState" nibble that means key-down, and the
    // `data1` bit layout it is packed into (top 16 bits: key code, next byte:
    // state, lowest bit: auto-repeat). Undocumented by Apple, but a
    // long-stable convention (MediaKeyTap, Karabiner).
    static let keyDownState: Int = 0x0A
    static let keyCodeMask: Int = 0xFFFF0000
    static let keyCodeShift: Int = 16
    static let keyStateMask: Int = 0xFF00
    static let keyStateShift: Int = 8
    static let repeatMask: Int = 0x1

    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: the subtype that marks a
    /// `systemDefined` event as a media-key event.
    static let auxControlButtonsSubtype: Int16 = 8

    /// The modifiers macOS itself gives a meaning to on a brightness key:
    /// Control adjusts an Apple external display, Option opens Displays
    /// settings, Command plus Brightness Down toggles mirroring. Shift and
    /// Option-Shift (finer steps) stay with BrightBoi, since letting macOS
    /// take them would change Nominal brightness behind the slider's back.
    private static let significantModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// Whether a media-key press carrying `flags` belongs to BrightBoi.
    /// Anything with Command, Control, or Option alone passes through to macOS.
    static func acceptsModifiers(_ flags: CGEventFlags) -> Bool {
        let held = flags.intersection(significantModifiers)
        return held.isEmpty || held == [.maskShift] || held == [.maskAlternate, .maskShift]
    }

    /// The press a brightness media key stands for, or `nil` when it is not a
    /// key-down of a direction still on its default, or carries a modifier
    /// macOS keeps for itself.
    static func mediaKeyPress(
        subtype: Int16,
        data1: Int,
        flags: CGEventFlags,
        plan: KeyTapPlan
    ) -> BrightnessController.KeyPress? {
        guard subtype == auxControlButtonsSubtype,
              ((data1 & keyStateMask) >> keyStateShift) == keyDownState,
              acceptsModifiers(flags) else { return nil }

        switch Int32((data1 & keyCodeMask) >> keyCodeShift) {
        case brightnessUpKeyCode where plan.raiseMediaKey: return .raise
        case brightnessDownKeyCode where plan.lowerMediaKey: return .lower
        default: return nil
        }
    }

    /// Whether a media-key event is the auto-repeat of a held key.
    static func isMediaKeyRepeat(data1: Int) -> Bool {
        (data1 & repeatMask) != 0
    }

    /// The press a custom combo stands for, when a hot key could not be
    /// registered for it and the tap reads it from ordinary key-down events
    /// instead.
    static func keyDownPress(
        keyCode: Int64,
        flags: CGEventFlags,
        fallback: [(press: BrightnessController.KeyPress, combo: KeyCombo)]
    ) -> BrightnessController.KeyPress? {
        let combo = KeyCombo(modifiers: KeyCombo.Modifiers(cgEventFlags: flags), keyCode: keyCode)
        return fallback.first { $0.combo == combo }?.press
    }
}

extension KeyCombo.Modifiers {
    /// The modifier set held in a `CGEvent`'s flags. Read straight from the
    /// flags, so a tap callback never has to allocate an `NSEvent`.
    init(cgEventFlags flags: CGEventFlags) {
        var modifiers: KeyCombo.Modifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        self = modifiers
    }

    /// The Carbon modifier mask `RegisterEventHotKey` expects
    /// (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= 1 << 8 }
        if contains(.shift) { mask |= 1 << 9 }
        if contains(.option) { mask |= 1 << 11 }
        if contains(.control) { mask |= 1 << 12 }
        return mask
    }
}

/// Decides whether an auto-repeat of a held key is applied or swallowed,
/// capping a held key at one step per `minimumInterval` whatever the system
/// key-repeat rate is. A press that is not a repeat always applies.
struct KeyRepeatLimiter {
    /// About 16 steps per second.
    static let defaultMinimumInterval: TimeInterval = 0.06

    let minimumInterval: TimeInterval
    private var lastApplied: TimeInterval?

    init(minimumInterval: TimeInterval = KeyRepeatLimiter.defaultMinimumInterval) {
        self.minimumInterval = minimumInterval
    }

    /// Whether a repeat at `time` arrives too soon after the last applied step.
    func isThrottled(isRepeat: Bool, at time: TimeInterval) -> Bool {
        guard isRepeat, let lastApplied else { return false }
        return time - lastApplied < minimumInterval
    }

    /// Records that a press was applied at `time`.
    mutating func recordApplied(at time: TimeInterval) {
        lastApplied = time
    }
}
