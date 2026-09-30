import CoreGraphics
import Foundation

/// How a `KeyRemapShortcut` reaches BrightBoi. The brightness keys only ever
/// arrive as `NX_SYSDEFINED` media-key events, which need an event tap (and so
/// the Accessibility permission). They are read as the combos F1 (brightness
/// down) and F2 (brightness up), so either direction can be given either key.
/// Any other combo is registered as a system hot key, which macOS delivers
/// even while Secure Keyboard Entry hides ordinary key events from every tap,
/// and which needs no permission at all.
struct KeyTapPlan: Equatable {
    private let raise: KeyCombo
    private let lower: KeyCombo

    /// The Raise direction listens to a brightness media key (F1 or F2).
    let raiseMediaKey: Bool
    /// The Lower direction listens to a brightness media key (F1 or F2).
    let lowerMediaKey: Bool
    /// A combo for the Raise direction that is neither F1 nor F2.
    let raiseHotKey: KeyCombo?
    /// A combo for the Lower direction that is neither F1 nor F2, and differs
    /// from the Raise combo (a hot key can be registered only once).
    let lowerHotKey: KeyCombo?

    init(remap: KeyRemapShortcut) {
        raise = remap.raise
        lower = remap.lower
        raiseMediaKey = Self.isMediaKey(remap.raise)
        lowerMediaKey = Self.isMediaKey(remap.lower)
        raiseHotKey = Self.isMediaKey(remap.raise) ? nil : remap.raise
        lowerHotKey = !Self.isMediaKey(remap.lower) && remap.lower != remap.raise ? remap.lower : nil
    }

    /// Whether any direction listens to the brightness media keys.
    var usesMediaKeys: Bool { raiseMediaKey || lowerMediaKey }

    /// The direction a brightness media key stands for under this remap, given
    /// as the combo it reads as (`.f1` for brightness down, `.f2` for up).
    func mediaKeyPress(for combo: KeyCombo) -> BrightnessController.KeyPress? {
        if raiseMediaKey, combo == raise { return .raise }
        if lowerMediaKey, combo == lower { return .lower }
        return nil
    }

    /// The custom combos to register, each with the press it triggers.
    var hotKeys: [(press: BrightnessController.KeyPress, combo: KeyCombo)] {
        var result: [(press: BrightnessController.KeyPress, combo: KeyCombo)] = []
        if let raiseHotKey { result.append((.raise, raiseHotKey)) }
        if let lowerHotKey { result.append((.lower, lowerHotKey)) }
        return result
    }

    private static func isMediaKey(_ combo: KeyCombo) -> Bool {
        combo == .f1 || combo == .f2
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

    /// The combo a brightness media key-down reads as: `.f1` for brightness
    /// down, `.f2` for brightness up. `nil` for anything else, including a
    /// key-up and a press carrying a modifier macOS keeps for itself.
    static func mediaKeyCombo(subtype: Int16, data1: Int, flags: CGEventFlags) -> KeyCombo? {
        guard subtype == auxControlButtonsSubtype,
              ((data1 & keyStateMask) >> keyStateShift) == keyDownState,
              acceptsModifiers(flags) else { return nil }

        switch Int32((data1 & keyCodeMask) >> keyCodeShift) {
        case brightnessUpKeyCode: return .f2
        case brightnessDownKeyCode: return .f1
        default: return nil
        }
    }

    /// The press a brightness media key stands for, or `nil` when it is not a
    /// key-down of a direction listening to that key, or carries a modifier
    /// macOS keeps for itself.
    static func mediaKeyPress(
        subtype: Int16,
        data1: Int,
        flags: CGEventFlags,
        plan: KeyTapPlan
    ) -> BrightnessController.KeyPress? {
        mediaKeyCombo(subtype: subtype, data1: data1, flags: flags).flatMap { plan.mediaKeyPress(for: $0) }
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

extension KeyTapMatcher {
    /// Whether a key press belongs to the recorder itself rather than being a
    /// candidate shortcut: Escape cancels, and Tab or Shift-Tab moves focus.
    static func isRecorderControlKey(keyCode: Int64, modifiers: KeyCombo.Modifiers) -> Bool {
        keyCode == 0x35 && modifiers.isEmpty
            || keyCode == 0x30 && modifiers.isSubset(of: [.shift])
    }

    /// The combo a key-down stands for while recording, or `nil` for the keys
    /// that belong to the recorder. A bare F1 or F2 key-down is also `nil`: it
    /// would read as the brightness media key, which it is not, so it is left
    /// to the recorder to refuse.
    static func capturedCombo(keyCode: Int64, flags: CGEventFlags) -> KeyCombo? {
        let modifiers = KeyCombo.Modifiers(cgEventFlags: flags)
        guard !isRecorderControlKey(keyCode: keyCode, modifiers: modifiers) else { return nil }
        if modifiers.isEmpty, keyCode == KeyCombo.f1.keyCode || keyCode == KeyCombo.f2.keyCode { return nil }
        return KeyCombo(modifiers: modifiers, keyCode: keyCode)
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
