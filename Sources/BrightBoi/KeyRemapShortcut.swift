import AppKit
import Foundation

/// One physical key plus the modifier keys held with it — the unit `RealKeyTap`
/// matches an incoming `CGEvent`/`NSEvent` against, and the unit the Settings
/// shortcut recorder produces. Uses the same flat virtual-keycode space
/// `CGEvent`/`NSEvent` already expose, so no separate keycode-to-string
/// translation table is needed to persist or compare a combo.
///
/// Persisted via synthesized `Codable` (see `RealBrightnessPersistence.save(keyRemapShortcut:)`):
/// new stored properties must be `Optional` (or add a hand-written
/// `init(from:)` using `decodeIfPresent`) — a non-optional property with a
/// default value still throws `keyNotFound` on an old record, silently
/// resetting an upgrader's custom shortcut to F1/F2. Never rename or retype
/// an existing property either; both break decoding the same way.
struct KeyCombo: Equatable, Hashable, Codable {
    struct Modifiers: OptionSet, Hashable, Codable {
        // Persisted as this raw `Int` in UserDefaults since v1.0.0 — never
        // renumber an existing bit. A decoded record with an unrecognized
        // bit still loads, but silently never matches any real event again.
        let rawValue: Int

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
    }

    var modifiers: Modifiers
    var keyCode: Int64

    // Standard virtual keycodes for the F1/F2 function keys (Carbon
    // HIToolbox constants `kVK_F1`/`kVK_F2`), the single source of truth for
    // the key tap and the shortcut recorder.
    static let f1VirtualKeyCode: Int64 = 0x7A
    static let f2VirtualKeyCode: Int64 = 0x78

    static let f1 = KeyCombo(modifiers: [], keyCode: f1VirtualKeyCode)
    static let f2 = KeyCombo(modifiers: [], keyCode: f2VirtualKeyCode)

    /// Whether the combo is a usable remap on its own, judged by the fixed
    /// rules only (see `ShortcutRejection`); the recorder adds checks that
    /// depend on the other direction and on this Mac's own shortcuts.
    var isValidRemap: Bool {
        remapRejection == nil
    }

    /// The label shown in Settings, such as "F1" or "⌃⌥↑". Character keys
    /// are named after the active keyboard layout.
    var displayString: String {
        modifierSymbols + KeyNames.name(for: keyCode).symbol
    }

    /// The combo as VoiceOver should say it, such as "Control Option Up Arrow".
    var spokenName: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        words.append(KeyNames.name(for: keyCode).spoken)
        return words.joined(separator: " ")
    }

    private var modifierSymbols: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }
}

extension KeyCombo.Modifiers {
    /// The conversion from `NSEvent.ModifierFlags` to `KeyCombo`'s own
    /// modifier set, used by the Settings shortcut recorder. The key tap reads
    /// `CGEventFlags` instead (see `init(cgEventFlags:)`); both count the same
    /// four keys as modifiers for remap purposes.
    init(nsEventModifierFlags flags: NSEvent.ModifierFlags) {
        var modifiers: KeyCombo.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}

/// The full configurable Key Remap: which combo raises vs. lowers
/// brightness. Defaults to the original hardcoded F1 (lower) / F2 (raise)
/// pair, matching today's behavior with no migration needed for existing
/// users.
///
/// Persisted via synthesized `Codable`, same frozen-format rule as
/// `KeyCombo` above: new properties must be `Optional`, existing ones must
/// never be renamed or retyped.
struct KeyRemapShortcut: Equatable, Codable {
    var raise: KeyCombo
    var lower: KeyCombo

    static let defaultShortcut = KeyRemapShortcut(raise: .f2, lower: .f1)

    /// Whether both combos are usable and they differ. F1 and F2 may be
    /// swapped: they stand for the brightness-down and brightness-up keys,
    /// whichever direction each is given.
    var isValid: Bool {
        raise.isValidRemap && lower.isValidRemap && raise != lower
    }
}
