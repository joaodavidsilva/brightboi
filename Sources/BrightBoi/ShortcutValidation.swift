import AppKit
import Carbon.HIToolbox

/// Why a combo can't be a brightness shortcut. `message` is the short hint
/// the recorder shows.
enum ShortcutRejection: Equatable {
    /// A typing key with no ⌘ or ⌃, which would steal ordinary typing.
    case needsModifier
    /// A shortcut macOS or nearly every app already uses.
    case reservedByMacOS
    /// ⌃⌥ with an arrow, which VoiceOver uses while it is running.
    case reservedByVoiceOver
    /// The combo already belongs to the other direction.
    case usedByOtherDirection(BrightnessController.KeyPress)
    /// Escape cancels recording, so it can't be recorded.
    case escape
    /// A plain F1 or F2 key-down, which is not the brightness key.
    case useBrightnessKey

    var message: String {
        switch self {
        case .needsModifier: "Add ⌘ or ⌃"
        case .reservedByMacOS: "Reserved by macOS"
        case .reservedByVoiceOver: "Reserved by VoiceOver"
        case .usedByOtherDirection(.raise): "Already used for Raise"
        case .usedByOtherDirection(.lower): "Already used for Lower"
        case .escape: "Esc cancels"
        case .useBrightnessKey: "Use Fn with F1 or F2"
        }
    }
}

/// What the validator needs to know about this Mac, kept apart from the fixed
/// rules so they can be tested anywhere.
struct ShortcutContext: Equatable {
    /// Enabled system-wide hot keys (Spaces, Mission Control, Spotlight, ...).
    var systemReserved: [KeyCombo] = []
    var voiceOverActive = false

    /// Read from the running system.
    @MainActor
    static func current() -> ShortcutContext {
        ShortcutContext(
            systemReserved: SystemHotKeys.enabled(),
            voiceOverActive: NSWorkspace.shared.isVoiceOverEnabled
        )
    }
}

extension KeyCombo {
    /// F1 and F2 with no modifier are the brightness media keys, so they need
    /// none. Every other combo goes through `remapRejection`.
    private var isBrightnessMediaKey: Bool { self == .f1 || self == .f2 }

    private static let reservedCommandShortcuts: Set<KeyCombo> = {
        func command(_ keyCode: Int64, _ extra: Modifiers = []) -> KeyCombo {
            var modifiers: Modifiers = .command
            modifiers.formUnion(extra)
            return KeyCombo(modifiers: modifiers, keyCode: keyCode)
        }
        // Key codes of the ANSI keys by name, so each entry reads as a key.
        let q: Int64 = 0x0C, w: Int64 = 0x0D, h: Int64 = 0x04, m: Int64 = 0x2E, n: Int64 = 0x2D
        let o: Int64 = 0x1F, p: Int64 = 0x23, s: Int64 = 0x01, t: Int64 = 0x11, f: Int64 = 0x03
        let a: Int64 = 0x00, c: Int64 = 0x08, v: Int64 = 0x09, x: Int64 = 0x07, z: Int64 = 0x06
        let tab: Int64 = 0x30, space: Int64 = 0x31, backtick: Int64 = 0x32, comma: Int64 = 0x2B
        var set = Set([q, w, h, m, n, o, p, s, t, f, a, c, v, x, z].map { command($0) })
        set.insert(command(z, .shift))
        for key in [tab, space, backtick, comma] { set.insert(command(key)) }
        return set
    }()

    /// The fixed rules a remap combo must pass:
    /// - typing keys (letters, digits, punctuation, Space, Return, Tab,
    ///   Delete, the keypad) need ⌘ or ⌃, since ⇧ and ⌥ alone type characters;
    /// - function keys and arrows and the navigation cluster take any
    ///   modifier, but no bare key, except F1 and F2, which are the
    ///   brightness keys themselves;
    /// - the standard ⌘ shortcuts (Quit, Close, Copy, ...) are reserved.
    var remapRejection: ShortcutRejection? {
        if isBrightnessMediaKey { return nil }
        if keyCode == 0x35 { return .escape }
        if Self.reservedCommandShortcuts.contains(self) { return .reservedByMacOS }
        if KeyNames.isFunctionKey(keyCode) || KeyNames.isNavigationKey(keyCode) {
            return modifiers.isEmpty ? .needsModifier : nil
        }
        return modifiers.contains(.command) || modifiers.contains(.control) ? nil : .needsModifier
    }
}

extension KeyRemapShortcut {
    /// Why `candidate` can't be the combo for `press`, or `nil` when it can:
    /// the fixed rules, then the other direction, then this Mac's own
    /// shortcuts described by `context`.
    func rejection(
        of candidate: KeyCombo,
        for press: BrightnessController.KeyPress,
        context: ShortcutContext = ShortcutContext()
    ) -> ShortcutRejection? {
        if let fixed = candidate.remapRejection { return fixed }
        switch press {
        case .raise where candidate == lower: return .usedByOtherDirection(.lower)
        case .lower where candidate == raise: return .usedByOtherDirection(.raise)
        default: break
        }
        if context.systemReserved.contains(candidate) { return .reservedByMacOS }
        if context.voiceOverActive,
           candidate.modifiers == [.control, .option],
           KeyNames.isNavigationKey(candidate.keyCode) {
            return .reservedByVoiceOver
        }
        return nil
    }

    /// The shortcut with `combo` assigned to `press`.
    func replacing(_ press: BrightnessController.KeyPress, with combo: KeyCombo) -> KeyRemapShortcut {
        switch press {
        case .raise: KeyRemapShortcut(raise: combo, lower: lower)
        case .lower: KeyRemapShortcut(raise: raise, lower: combo)
        }
    }
}

/// The system-wide hot keys macOS has enabled (Spaces, Mission Control,
/// Spotlight, screenshots, ...), read from the symbolic hot key table.
enum SystemHotKeys {
    static func enabled() -> [KeyCombo] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() else { return [] }
        return combos(from: (array as? [[String: Any]]) ?? [])
    }

    /// Parses entries of the symbolic hot key table. Disabled entries and
    /// entries with no key are skipped. The Fn flag is ignored, and any entry
    /// that then reads as a bare F1 or F2 is dropped, so the brightness keys
    /// themselves never count as taken.
    static func combos(from entries: [[String: Any]]) -> [KeyCombo] {
        entries.compactMap { entry in
            guard let enabled = entry[kHISymbolicHotKeyEnabled as String] as? Bool, enabled,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int, (0...0x7F).contains(code),
                  let flags = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }
            let combo = KeyCombo(modifiers: KeyCombo.Modifiers(carbonModifiers: UInt32(truncatingIfNeeded: flags)), keyCode: Int64(code))
            return combo == .f1 || combo == .f2 ? nil : combo
        }
    }
}

extension KeyCombo.Modifiers {
    /// The four modifiers in a Carbon modifier mask, ignoring the rest.
    init(carbonModifiers mask: UInt32) {
        var modifiers: KeyCombo.Modifiers = []
        if mask & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        if mask & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if mask & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if mask & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        self = modifiers
    }
}
