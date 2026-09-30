import AppKit
import Carbon.HIToolbox

/// How a virtual keycode is written in a shortcut label and how it is read
/// aloud. Keys that print the same thing on every keyboard (function keys,
/// arrows, editing keys, the keypad) come from a fixed table. Keys that print
/// something different per layout (letters, digits, punctuation) are read
/// from the keyboard layout currently in use, with a US table as the fallback.
enum KeyNames {
    struct Name: Equatable {
        /// What a menu would show, such as "↖" or "F13".
        let symbol: String
        /// What VoiceOver should say, such as "Home" or "F13".
        let spoken: String

        init(_ symbol: String, spoken: String? = nil) {
            self.symbol = symbol
            self.spoken = spoken ?? symbol
        }
    }

    /// Keys whose name does not depend on the keyboard layout.
    static let fixed: [Int64: Name] = {
        var table: [Int64: Name] = [
            0x31: Name("Space"),
            0x24: Name("↩", spoken: "Return"),
            0x30: Name("⇥", spoken: "Tab"),
            0x33: Name("⌫", spoken: "Delete"),
            0x75: Name("⌦", spoken: "Forward Delete"),
            0x35: Name("⎋", spoken: "Escape"),
            0x72: Name("Help"),
            0x6E: Name("Menu"),
            0x73: Name("↖", spoken: "Home"),
            0x77: Name("↘", spoken: "End"),
            0x74: Name("⇞", spoken: "Page Up"),
            0x79: Name("⇟", spoken: "Page Down"),
            0x7B: Name("←", spoken: "Left Arrow"),
            0x7C: Name("→", spoken: "Right Arrow"),
            0x7E: Name("↑", spoken: "Up Arrow"),
            0x7D: Name("↓", spoken: "Down Arrow"),
            0x4C: Name("⌤", spoken: "Keypad Enter"),
            0x47: Name("⌧", spoken: "Keypad Clear"),
            0x41: Name("Keypad ."),
            0x43: Name("Keypad *"),
            0x45: Name("Keypad +"),
            0x4B: Name("Keypad /"),
            0x4E: Name("Keypad -"),
            0x51: Name("Keypad ="),
            0x5F: Name("Keypad ,")
        ]
        for (index, keyCode) in functionKeyCodes.enumerated() {
            table[keyCode] = Name("F\(index + 1)")
        }
        // The keypad digits are not contiguous: 0x52-0x59 are 0-7, then 8 and 9.
        for (digit, keyCode) in [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C].enumerated() {
            table[Int64(keyCode)] = Name("Keypad \(digit)")
        }
        return table
    }()

    /// F1 to F20, in order.
    static let functionKeyCodes: [Int64] = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A
    ]

    /// Arrows and the navigation cluster: keys that move the cursor or the
    /// view, so they are safe to use with a single modifier.
    static let navigationKeyCodes: Set<Int64> = [
        0x7B, 0x7C, 0x7E, 0x7D, 0x73, 0x77, 0x74, 0x79, 0x72
    ]

    static func isFunctionKey(_ keyCode: Int64) -> Bool { functionKeyCodes.contains(keyCode) }
    static func isNavigationKey(_ keyCode: Int64) -> Bool { navigationKeyCodes.contains(keyCode) }

    /// Letters, digits and punctuation on a US ANSI keyboard: the fallback
    /// when the active layout can't be read. Also the set of keys that are
    /// looked up in the layout in the first place.
    static let usCharacters: [Int64: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
        0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";", 0x27: "'",
        0x2B: ",", 0x2F: ".", 0x2C: "/", 0x32: "`", 0x18: "=", 0x1B: "-",
        0x0A: "§", 0x5D: "¥", 0x5E: "_"
    ]

    /// The label for `keyCode`. `layoutName` supplies the character the
    /// active keyboard layout prints on the key; the US table answers when it
    /// has none.
    static func name(for keyCode: Int64, layoutName: (Int64) -> String? = KeyboardLayoutNames.currentName) -> Name {
        if let name = fixed[keyCode] { return name }
        if let fallback = usCharacters[keyCode] {
            return Name(layoutName(keyCode) ?? fallback)
        }
        return Name("Key \(keyCode)")
    }
}

/// Reads the character the keyboard layout in use prints on a key, for the
/// shortcut labels. The Text Input Sources API may only be used from the main
/// thread, so any other thread gets `nil` and falls back to the US table.
@MainActor
@Observable
final class KeyboardLayoutNames {
    static let shared = KeyboardLayoutNames()

    /// Changes whenever the selected layout does. Views read it so they
    /// redraw their shortcut labels when the user switches layout.
    private(set) var generation = 0

    @ObservationIgnored private var cache: [Int64: String?] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                KeyboardLayoutNames.shared.layoutChanged()
            }
        }
    }

    /// The printed character for `keyCode` on the current layout, upper-cased,
    /// or `nil` when it can't be determined here.
    nonisolated static func currentName(for keyCode: Int64) -> String? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { shared.name(for: keyCode) }
    }

    func name(for keyCode: Int64) -> String? {
        if let cached = cache[keyCode] { return cached }
        let resolved = Self.readCurrentLayout(keyCode: keyCode)
        cache[keyCode] = .some(resolved)
        return resolved
    }

    private func layoutChanged() {
        cache.removeAll()
        generation += 1
    }

    private static func readCurrentLayout(keyCode: Int64) -> String? {
        for source in [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        ] {
            guard let source,
                  let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            if let name = translate(keyCode: keyCode, layoutData: data) { return name }
        }
        return nil
    }

    /// What `layoutData` prints on `keyCode` with no modifier held. Dead keys
    /// (such as ´) still yield their character. `nil` for an empty or control
    /// result.
    nonisolated static func translate(keyCode: Int64, layoutData: CFData) -> String? {
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeys,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        guard text.unicodeScalars.allSatisfy({ !$0.properties.generalCategory.isControlOrFormat }) else { return nil }
        let upper = text.uppercased()
        return upper.count == 1 ? upper : text
    }
}

private extension Unicode.GeneralCategory {
    var isControlOrFormat: Bool {
        self == .control || self == .format || self == .unassigned
    }
}
