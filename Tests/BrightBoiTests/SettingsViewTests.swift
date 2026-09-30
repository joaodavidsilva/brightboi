import Foundation
import Testing
@testable import BrightBoi

@Suite("SettingsView copy")
struct SettingsViewTests {

    private let custom = KeyRemapShortcut(
        raise: KeyCombo(modifiers: [.control, .option], keyCode: 126),
        lower: KeyCombo(modifiers: [.control, .option], keyCode: 125)
    )

    // MARK: - Key Remap subtitle

    @Test("a lowered ceiling names its own range")
    func subtitleWithCeiling150() {
        let text = SettingsView.remapSubtitle(shortcut: .defaultShortcut, supportsBoost: true, boostCeiling: 150)
        #expect(text == "The brightness keys step 5% at a time across 0\u{2060}–\u{2060}150%, past the usual 100% stop.")
    }

    @Test("the range is joined so it can't wrap at the en dash")
    func subtitleKeepsRangeTogether() {
        let text = SettingsView.remapSubtitle(shortcut: .defaultShortcut, supportsBoost: true, boostCeiling: 200)
        #expect(text.contains("0\u{2060}–\u{2060}200%"))
    }

    @Test("a ceiling at 100% has no range clause")
    func subtitleWithCeiling100() {
        let text = SettingsView.remapSubtitle(shortcut: .defaultShortcut, supportsBoost: true, boostCeiling: 100)
        #expect(text == "The brightness keys step 5% at a time.")
    }

    @Test("a Mac without Boost makes no 0-200% claim")
    func subtitleWithoutBoost() {
        let text = SettingsView.remapSubtitle(shortcut: .defaultShortcut, supportsBoost: false, boostCeiling: 200)
        #expect(text == "Each press moves brightness 5%.")
    }

    @Test("a custom shortcut says 'These keys'")
    func subtitleWithCustomShortcut() {
        let text = SettingsView.remapSubtitle(shortcut: custom, supportsBoost: true, boostCeiling: 150)
        #expect(text.hasPrefix("These keys step 5% at a time"))
    }

    // MARK: - Key Remap title

    @Test("the title lists lower then raise, and reads F1 / F2 for the default")
    func remapTitleOrder() {
        #expect(SettingsView.remapToggleTitle(.defaultShortcut) == "Let BrightBoi own F1 / F2")
        let title = SettingsView.remapToggleTitle(custom)
        #expect(title == "Let BrightBoi own \(custom.lower.displayString) / \(custom.raise.displayString)")
    }

    // MARK: - Version

    @Test("no Info.plist reads dev")
    func versionWithoutInfo() {
        #expect(SettingsView.versionLabel(info: nil) == "BrightBoi dev · built-in display only")
    }

    @Test("an Info.plist without the version key reads dev")
    func versionMissingKey() {
        #expect(SettingsView.versionLabel(info: ["CFBundleName": "BrightBoi"]) == "BrightBoi dev · built-in display only")
    }

    @Test("a populated Info.plist shows the version, with the build when present")
    func versionPopulated() {
        #expect(SettingsView.versionLabel(info: ["CFBundleShortVersionString": "1.1.0"]) == "BrightBoi 1.1.0 · built-in display only")
        #expect(
            SettingsView.versionLabel(info: ["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "3"])
                == "BrightBoi 1.1.0 (3) · built-in display only"
        )
    }
}
