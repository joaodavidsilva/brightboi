import AppKit
import Testing
@testable import BrightBoi

@Suite("KeyCombo remap validity")
struct KeyRemapShortcutTests {

    // MARK: displayString

    @Test("displayString shows F1/F2 as bare, with no modifier symbols")
    func displayStringForFunctionKeys() {
        #expect(KeyCombo.f1.displayString == "F1")
        #expect(KeyCombo.f2.displayString == "F2")
    }

    @Test("displayString renders modifier symbols in a fixed order, then the key name")
    func displayStringForModifiedCombo() {
        let combo = KeyCombo(modifiers: [.control, .option], keyCode: 0x7E)
        #expect(combo.displayString == "⌃⌥↑")
    }

    @Test("displayString falls back to a numbered label for a keycode with no name")
    func displayStringForUnknownKeyCode() {
        let combo = KeyCombo(modifiers: [.command], keyCode: 9999)
        #expect(combo.displayString == "⌘Key 9999")
    }

    @Test("displayString names the function keys F13 to F20")
    func displayStringForExtendedFunctionKeys() {
        let codes: [Int64] = [0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (index, code) in codes.enumerated() {
            #expect(KeyCombo(modifiers: [.control], keyCode: code).displayString == "⌃F\(index + 13)")
        }
    }

    @Test("displayString uses Apple's glyphs for navigation and editing keys")
    func displayStringForNavigationKeys() {
        #expect(KeyCombo(modifiers: [.option], keyCode: 0x73).displayString == "⌥↖")
        #expect(KeyCombo(modifiers: [.option], keyCode: 0x77).displayString == "⌥↘")
        #expect(KeyCombo(modifiers: [.option], keyCode: 0x74).displayString == "⌥⇞")
        #expect(KeyCombo(modifiers: [.option], keyCode: 0x79).displayString == "⌥⇟")
        #expect(KeyCombo(modifiers: [.command], keyCode: 0x75).displayString == "⌘⌦")
        #expect(KeyCombo(modifiers: [.command], keyCode: 0x72).displayString == "⌘Help")
    }

    @Test("displayString writes Return, Tab and Delete as glyphs")
    func displayStringForEditingGlyphs() {
        #expect(KeyCombo(modifiers: [.command], keyCode: 0x24).displayString == "⌘↩")
        #expect(KeyCombo(modifiers: [.command], keyCode: 0x30).displayString == "⌘⇥")
        #expect(KeyCombo(modifiers: [.command], keyCode: 0x33).displayString == "⌘⌫")
    }

    @Test("keypad digits are labelled apart from the number row")
    func displayStringForKeypad() {
        let keypad: [Int64] = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
        for (digit, code) in keypad.enumerated() {
            #expect(KeyCombo(modifiers: [.control], keyCode: code).displayString == "⌃Keypad \(digit)")
        }
        #expect(KeyCombo(modifiers: [.control], keyCode: 0x4C).displayString == "⌃⌤")
    }

    @Test("no key the table knows renders as a numbered label")
    func noKnownKeyRendersAsNumber() {
        let known: [Int64] = [0x0A, 0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51, 0x6E, 0x72, 0x73, 0x74, 0x75, 0x77, 0x79] + KeyNames.functionKeyCodes
        for code in known {
            #expect(KeyCombo(modifiers: [.control], keyCode: code).displayString.contains("Key ") == false)
        }
    }

    @Test("a character key takes the layout's name when there is one, and the US name otherwise")
    func characterKeyUsesLayoutName() {
        #expect(KeyNames.name(for: 0x29, layoutName: { _ in "Ç" }).symbol == "Ç")
        #expect(KeyNames.name(for: 0x29, layoutName: { _ in nil }).symbol == ";")
        // Keys that print the same everywhere never ask the layout.
        #expect(KeyNames.name(for: 0x7E, layoutName: { _ in "X" }).symbol == "↑")
    }

    @Test("spokenName says modifiers and keys in words")
    func spokenNames() {
        #expect(KeyCombo.f2.spokenName == "F2")
        #expect(KeyCombo(modifiers: [.control, .option], keyCode: 0x7E).spokenName == "Control Option Up Arrow")
        #expect(KeyCombo(modifiers: [.shift, .command], keyCode: 0x79).spokenName == "Shift Command Page Down")
        #expect(KeyCombo(modifiers: [.command], keyCode: 0x24).spokenName == "Command Return")
    }

    // MARK: Modifiers(nsEventModifierFlags:)

    @Test("Modifiers(nsEventModifierFlags:) carries over exactly the four flags that matter")
    func modifiersFromNSEventFlags() {
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        let modifiers = KeyCombo.Modifiers(nsEventModifierFlags: flags)
        #expect(modifiers == [.command, .shift])
    }

    @Test("Modifiers(nsEventModifierFlags:) ignores flags KeyCombo doesn't model, e.g. .function")
    func modifiersFromNSEventFlagsIgnoresUnmodeledFlags() {
        let flags: NSEvent.ModifierFlags = [.control, .function]
        let modifiers = KeyCombo.Modifiers(nsEventModifierFlags: flags)
        #expect(modifiers == [.control])
    }

    // MARK: Codable — the direction that protects existing users' shortcuts

    @Test("decoding the golden default-shortcut JSON equals .defaultShortcut")
    func decodesGoldenDefaultShortcutJSON() throws {
        let json = #"{"lower":{"keyCode":122,"modifiers":0},"raise":{"keyCode":120,"modifiers":0}}"#
        let decoded = try JSONDecoder().decode(KeyRemapShortcut.self, from: Data(json.utf8))
        #expect(decoded == .defaultShortcut)
    }

    @Test("encoding with sortedKeys matches the documented byte-for-byte format")
    func encodesWithSortedKeysMatchesDocumentedFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(KeyRemapShortcut.defaultShortcut)
        #expect(String(data: data, encoding: .utf8) == #"{"lower":{"keyCode":122,"modifiers":0},"raise":{"keyCode":120,"modifiers":0}}"#)
    }

    // MARK: Validity

    private func reject(_ modifiers: KeyCombo.Modifiers, _ keyCode: Int64) -> ShortcutRejection? {
        KeyCombo(modifiers: modifiers, keyCode: keyCode).remapRejection
    }

    @Test("bare F1 and F2 are valid: they are the brightness keys")
    func bareF1F2Valid() {
        #expect(KeyCombo.f1.isValidRemap)
        #expect(KeyCombo.f2.isValidRemap)
    }

    @Test("a bare letter, digit or other function key is rejected")
    func bareKeysRejected() {
        #expect(reject([], 0x0B) == .needsModifier)
        #expect(reject([], 0x12) == .needsModifier)
        #expect(reject([], 0x60) == .needsModifier) // F5
        #expect(reject([], 0x7E) == .needsModifier) // up arrow
    }

    @Test("Shift or Option with a typing key is rejected")
    func shiftAndOptionTypingCombosRejected() {
        #expect(reject([.shift], 0x00) == .needsModifier)   // ⇧A
        #expect(reject([.option], 0x0E) == .needsModifier)  // ⌥E, an accent key
        #expect(reject([.option], 0x25) == .needsModifier)  // ⌥L
        #expect(reject([.option, .shift], 0x0B) == .needsModifier) // ⌥⇧B
        #expect(reject([.shift], 0x31) == .needsModifier)   // ⇧Space
    }

    @Test("Control or Command with a typing key is accepted")
    func controlOrCommandTypingCombosAccepted() {
        #expect(reject([.control, .option], 0x0B) == nil)   // ⌃⌥B
        #expect(reject([.control], 0x0B) == nil)
        #expect(reject([.command], 0x0B) == nil)            // ⌘B
        #expect(reject([.command, .shift], 0x0B) == nil)
    }

    @Test("function keys, arrows and navigation keys take any modifier")
    func navigationKeysTakeAnyModifier() {
        #expect(reject([.shift], 0x60) == nil)              // ⇧F5
        #expect(reject([.option], 0x69) == nil)             // ⌥F13
        #expect(reject([.control, .option], 0x7E) == nil)   // ⌃⌥↑
        #expect(reject([.shift], 0x73) == nil)              // ⇧Home
    }

    @Test("the standard Command shortcuts are reserved")
    func reservedCommandShortcuts() {
        let letters: [Int64] = [0x0C, 0x0D, 0x04, 0x2E, 0x2D, 0x1F, 0x23, 0x01, 0x11, 0x03, 0x00, 0x08, 0x09, 0x07, 0x06]
        for code in letters {
            #expect(reject([.command], code) == .reservedByMacOS)
        }
        #expect(reject([.command, .shift], 0x06) == .reservedByMacOS) // ⌘⇧Z
        #expect(reject([.command], 0x30) == .reservedByMacOS)         // ⌘Tab
        #expect(reject([.command], 0x31) == .reservedByMacOS)         // ⌘Space
        #expect(reject([.command], 0x32) == .reservedByMacOS)         // ⌘`
        #expect(reject([.command], 0x2B) == .reservedByMacOS)         // ⌘,
    }

    @Test("Escape is never a shortcut")
    func escapeRejected() {
        #expect(reject([.control], 0x35) == .escape)
    }

    @Test("isValidRemap is true exactly when there is no rejection")
    func isValidRemapMatchesRejection() {
        #expect(KeyCombo(modifiers: [.command], keyCode: 0x0C).isValidRemap == false)
        #expect(KeyCombo(modifiers: [.control, .option], keyCode: 0x0B).isValidRemap)
    }

    // MARK: Whole shortcut

    @Test("a shortcut needs two valid, different combos")
    func shortcutValidity() {
        let up = KeyCombo(modifiers: [.control, .option], keyCode: 0x7E)
        #expect(KeyRemapShortcut.defaultShortcut.isValid)
        #expect(KeyRemapShortcut(raise: up, lower: up).isValid == false)
        #expect(KeyRemapShortcut(raise: up, lower: KeyCombo(modifiers: [.shift], keyCode: 0x00)).isValid == false)
    }

    @Test("F1 and F2 may be swapped")
    func swappedFunctionKeysValid() {
        #expect(KeyRemapShortcut(raise: .f1, lower: .f2).isValid)
    }

    @Test("recording a combo the other direction uses names that direction")
    func duplicateRejectionNamesOtherDirection() {
        let shortcut = KeyRemapShortcut.defaultShortcut
        #expect(shortcut.rejection(of: .f1, for: .raise) == .usedByOtherDirection(.lower))
        #expect(shortcut.rejection(of: .f2, for: .lower) == .usedByOtherDirection(.raise))
        #expect(ShortcutRejection.usedByOtherDirection(.lower).message == "Already used for Lower")
        #expect(ShortcutRejection.usedByOtherDirection(.raise).message == "Already used for Raise")
        // Re-recording a direction's own combo is fine.
        #expect(shortcut.rejection(of: .f2, for: .raise) == nil)
    }

    @Test("rejection messages are specific")
    func rejectionMessages() {
        #expect(ShortcutRejection.needsModifier.message == "Add ⌘ or ⌃")
        #expect(ShortcutRejection.reservedByMacOS.message == "Reserved by macOS")
    }

    @Test("an enabled system hot key is reserved")
    func systemHotKeysReserved() {
        let spaceLeft = KeyCombo(modifiers: [.control], keyCode: 0x7B)
        let context = ShortcutContext(systemReserved: [spaceLeft])
        #expect(KeyRemapShortcut.defaultShortcut.rejection(of: spaceLeft, for: .raise, context: context) == .reservedByMacOS)
        #expect(KeyRemapShortcut.defaultShortcut.rejection(of: spaceLeft, for: .raise) == nil)
    }

    @Test("Control-Option with an arrow is reserved only while VoiceOver runs")
    func voiceOverReservation() {
        let combo = KeyCombo(modifiers: [.control, .option], keyCode: 0x7E)
        let on = ShortcutContext(voiceOverActive: true)
        #expect(KeyRemapShortcut.defaultShortcut.rejection(of: combo, for: .raise, context: on) == .reservedByVoiceOver)
        #expect(KeyRemapShortcut.defaultShortcut.rejection(of: combo, for: .raise) == nil)
    }

    @Test("replacing one direction keeps the other")
    func replacingKeepsOther() {
        let combo = KeyCombo(modifiers: [.control, .option], keyCode: 0x7E)
        #expect(KeyRemapShortcut.defaultShortcut.replacing(.raise, with: combo) == KeyRemapShortcut(raise: combo, lower: .f1))
        #expect(KeyRemapShortcut.defaultShortcut.replacing(.lower, with: combo) == KeyRemapShortcut(raise: .f2, lower: combo))
    }

    // MARK: System hot key table

    @Test("system hot keys read only enabled entries, ignore the Fn flag and drop bare F1/F2")
    func systemHotKeyParsing() {
        let entries: [[String: Any]] = [
            ["kHISymbolicHotKeyCode": 123, "kHISymbolicHotKeyModifiers": 0x21000, "kHISymbolicHotKeyEnabled": true],
            ["kHISymbolicHotKeyCode": 124, "kHISymbolicHotKeyModifiers": 0x1000, "kHISymbolicHotKeyEnabled": false],
            ["kHISymbolicHotKeyCode": 122, "kHISymbolicHotKeyModifiers": 0x20000, "kHISymbolicHotKeyEnabled": true],
            ["kHISymbolicHotKeyCode": 120, "kHISymbolicHotKeyModifiers": 0x20000, "kHISymbolicHotKeyEnabled": true],
            ["kHISymbolicHotKeyCode": 65535, "kHISymbolicHotKeyModifiers": 0, "kHISymbolicHotKeyEnabled": true],
            ["kHISymbolicHotKeyCode": 49, "kHISymbolicHotKeyModifiers": 0x0300, "kHISymbolicHotKeyEnabled": true]
        ]
        #expect(SystemHotKeys.combos(from: entries) == [
            KeyCombo(modifiers: [.control], keyCode: 123),
            KeyCombo(modifiers: [.command, .shift], keyCode: 49)
        ])
    }

    @Test("the running system's hot key table can be read")
    func systemHotKeysReadable() {
        // Any Mac has at least one symbolic hot key enabled (Mission Control, Spotlight).
        #expect(SystemHotKeys.enabled().isEmpty == false)
    }

    @Test("the default shortcut pairs F2 (raise) with F1 (lower)")
    func defaultShortcutMatchesOriginalKeys() {
        #expect(KeyRemapShortcut.defaultShortcut.raise == .f2)
        #expect(KeyRemapShortcut.defaultShortcut.lower == .f1)
    }
}
