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

    @Test("F1 is a valid remap combo with no modifier")
    func f1ValidWithoutModifier() {
        #expect(KeyCombo.f1.isValidRemap)
    }

    @Test("F2 is a valid remap combo with no modifier")
    func f2ValidWithoutModifier() {
        #expect(KeyCombo.f2.isValidRemap)
    }

    @Test("a bare, unmodified letter key is rejected")
    func bareLetterKeyRejected() {
        let combo = KeyCombo(modifiers: [], keyCode: 0x0B) // "B"
        #expect(combo.isValidRemap == false)
    }

    @Test("a bare, unmodified digit key is rejected")
    func bareDigitKeyRejected() {
        let combo = KeyCombo(modifiers: [], keyCode: 0x12) // "1"
        #expect(combo.isValidRemap == false)
    }

    @Test("a single modifier is enough to make a combo valid")
    func singleModifierAccepted() {
        let combo = KeyCombo(modifiers: [.command], keyCode: 0x00)
        #expect(combo.isValidRemap)
    }

    @Test("multiple modifiers are also valid")
    func multipleModifiersAccepted() {
        let combo = KeyCombo(modifiers: [.option, .shift], keyCode: 0x0B)
        #expect(combo.isValidRemap)
    }

    @Test("the default shortcut pairs F2 (raise) with F1 (lower)")
    func defaultShortcutMatchesOriginalKeys() {
        #expect(KeyRemapShortcut.defaultShortcut.raise == .f2)
        #expect(KeyRemapShortcut.defaultShortcut.lower == .f1)
    }
}
