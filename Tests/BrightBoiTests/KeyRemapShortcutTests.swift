import Testing
@testable import BrightBoi

@Suite("KeyCombo remap validity")
struct KeyRemapShortcutTests {

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
