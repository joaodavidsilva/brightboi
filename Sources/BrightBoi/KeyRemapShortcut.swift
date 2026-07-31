import AppKit
import Foundation

/// One physical key plus the modifier keys held with it — the unit `RealKeyTap`
/// matches an incoming `CGEvent`/`NSEvent` against, and the unit the Settings
/// shortcut recorder produces. Uses the same flat virtual-keycode space
/// `CGEvent`/`NSEvent` already expose, so no separate keycode-to-string
/// translation table is needed to persist or compare a combo.
struct KeyCombo: Equatable, Codable {
    struct Modifiers: OptionSet, Codable {
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
    // HIToolbox constants `kVK_F1`/`kVK_F2`) — the same values `RealKeyTap`
    // hardcoded before this ticket, now the single source of truth both the
    // tap and the shortcut recorder read from.
    static let f1VirtualKeyCode: Int64 = 0x7A
    static let f2VirtualKeyCode: Int64 = 0x78

    static let f1 = KeyCombo(modifiers: [], keyCode: f1VirtualKeyCode)
    static let f2 = KeyCombo(modifiers: [], keyCode: f2VirtualKeyCode)

    /// Per ADR-0007: every remap combination must include at least one
    /// modifier (⌘/⌥/⌃/⇧), except F1/F2 themselves — dedicated media keys
    /// with no ordinary-typing collision risk, which is why the original
    /// hardcoded tap never needed this guard.
    var isValidRemap: Bool {
        !modifiers.isEmpty || self == .f1 || self == .f2
    }

    var displayString: String {
        if self == .f1 { return "F1" }
        if self == .f2 { return "F2" }

        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + Self.keyCodeName(keyCode)
    }

    private static func keyCodeName(_ keyCode: Int64) -> String {
        keyCodeNames[keyCode] ?? "Key \(keyCode)"
    }

    // US ANSI layout virtual keycodes only — good enough for this app's
    // scope. A fully layout-aware name would need `UCKeyTranslate`, which
    // isn't worth the complexity for a shortcut label.
    private static let keyCodeNames: [Int64: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
        0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x31: "Space", 0x24: "Return", 0x30: "Tab", 0x33: "Delete", 0x35: "Escape",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x7B: "←", 0x7C: "→", 0x7E: "↑", 0x7D: "↓",
        0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";", 0x27: "'",
        0x2B: ",", 0x2F: ".", 0x2C: "/", 0x32: "`", 0x18: "=", 0x1B: "-"
    ]
}

extension KeyCombo.Modifiers {
    /// The single conversion from `NSEvent.ModifierFlags` to `KeyCombo`'s own
    /// modifier set — used both by `RealKeyTap` (via `NSEvent(cgEvent:)`, the
    /// same bridge it already uses for the media-key path) and the Settings
    /// shortcut recorder, so there's one place that knows which raw flags
    /// count as a "modifier" for remap purposes.
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
struct KeyRemapShortcut: Equatable, Codable {
    var raise: KeyCombo
    var lower: KeyCombo

    static let defaultShortcut = KeyRemapShortcut(raise: .f2, lower: .f1)
}
