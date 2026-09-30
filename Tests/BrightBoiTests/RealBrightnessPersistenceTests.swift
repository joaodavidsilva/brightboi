import Foundation
import Testing
@testable import BrightBoi

/// Exercises `RealBrightnessPersistence` against a real, isolated
/// `UserDefaults` suite — every other suite drives `BrightnessController`
/// through `FakeBrightnessPersistence`, which never touches this type at
/// all. Each test gets its own UUID-named suite and tears it down in a
/// `defer`, so no run leaves a stray domain behind and tests can run in
/// parallel without clobbering each other's keys.
@Suite("RealBrightnessPersistence")
struct RealBrightnessPersistenceTests {

    private func makeSuite() -> (name: String, defaults: UserDefaults) {
        let name = "BrightBoiTests.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    // MARK: loadPercentage

    @Test("a missing percentage key returns nil")
    func missingPercentageReturnsNil() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(RealBrightnessPersistence(defaults: defaults).loadPercentage() == nil)
    }

    @Test("a saved 0% round-trips as exactly 0, not nil")
    func savedZeroPercentageRoundTrips() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let persistence = RealBrightnessPersistence(defaults: defaults)
        persistence.save(percentage: 0)
        #expect(persistence.loadPercentage() == 0)
    }

    @Test("a wrong-typed stored percentage (a String) returns nil, not the old 100% default")
    func wrongTypedPercentageReturnsNil() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("bogus", forKey: "com.ptlghost.BrightBoi.percentage")
        #expect(RealBrightnessPersistence(defaults: defaults).loadPercentage() == nil)
    }

    @Test("an Int-stored percentage still bridges to Double")
    func intStoredPercentageBridges() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(70, forKey: "com.ptlghost.BrightBoi.percentage")
        #expect(RealBrightnessPersistence(defaults: defaults).loadPercentage() == 70)
    }

    @Test("a NaN stored percentage returns nil")
    func nanPercentageReturnsNil() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Double.nan, forKey: "com.ptlghost.BrightBoi.percentage")
        #expect(RealBrightnessPersistence(defaults: defaults).loadPercentage() == nil)
    }

    @Test("an infinite stored percentage returns nil")
    func infinitePercentageReturnsNil() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Double.infinity, forKey: "com.ptlghost.BrightBoi.percentage")
        #expect(RealBrightnessPersistence(defaults: defaults).loadPercentage() == nil)
    }

    // MARK: loadBoostCeiling

    @Test("a missing Boost Ceiling key returns nil")
    func missingBoostCeilingReturnsNil() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(RealBrightnessPersistence(defaults: defaults).loadBoostCeiling() == nil)
    }

    @Test("a NaN stored Boost Ceiling returns nil")
    func nanBoostCeilingReturnsNil() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Double.nan, forKey: "com.ptlghost.BrightBoi.boostCeiling")
        #expect(RealBrightnessPersistence(defaults: defaults).loadBoostCeiling() == nil)
    }

    // MARK: Key Remap shortcut — round trip and schema pinning

    @Test("a Key Remap shortcut round-trips through save/load")
    func keyRemapShortcutRoundTrips() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let persistence = RealBrightnessPersistence(defaults: defaults)
        let shortcut = KeyRemapShortcut(
            raise: KeyCombo(modifiers: [.control, .option], keyCode: 0x7E),
            lower: KeyCombo(modifiers: [.control, .option], keyCode: 0x7D)
        )
        persistence.save(keyRemapShortcut: shortcut)
        #expect(persistence.loadKeyRemapShortcut() == shortcut)
    }

    @Test("corrupt shortcut Data returns nil rather than trapping")
    func corruptShortcutDataReturnsNil() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("not json".utf8), forKey: "com.ptlghost.BrightBoi.keyRemapShortcut")
        #expect(RealBrightnessPersistence(defaults: defaults).loadKeyRemapShortcut() == nil)
    }

    /// Pins the exact v1.x on-disk format — the literal key name and the
    /// literal JSON a real ⌃⌥↑ (raise) / ⌃⌥↓ (lower) shortcut encodes as.
    /// A future change to `KeyCombo`/`KeyRemapShortcut` that breaks this is
    /// exactly the regression #103 exists to catch.
    @Test("decodes the exact v1.x custom-shortcut record")
    func decodesPinnedV1CustomRecord() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(
            Data(#"{"lower":{"keyCode":125,"modifiers":6},"raise":{"keyCode":126,"modifiers":6}}"#.utf8),
            forKey: "com.ptlghost.BrightBoi.keyRemapShortcut"
        )
        let expected = KeyRemapShortcut(
            raise: KeyCombo(modifiers: [.control, .option], keyCode: 0x7E),
            lower: KeyCombo(modifiers: [.control, .option], keyCode: 0x7D)
        )
        #expect(RealBrightnessPersistence(defaults: defaults).loadKeyRemapShortcut() == expected)
    }

    @Test("decodes the default F1/F2 record")
    func decodesPinnedDefaultRecord() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(
            Data(#"{"lower":{"keyCode":122,"modifiers":0},"raise":{"keyCode":120,"modifiers":0}}"#.utf8),
            forKey: "com.ptlghost.BrightBoi.keyRemapShortcut"
        )
        #expect(RealBrightnessPersistence(defaults: defaults).loadKeyRemapShortcut() == .defaultShortcut)
    }

    @Test("a record with an extra unknown key still decodes")
    func recordWithExtraKeyStillDecodes() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(
            Data(#"{"lower":{"keyCode":122,"modifiers":0},"raise":{"keyCode":120,"modifiers":0},"future":true}"#.utf8),
            forKey: "com.ptlghost.BrightBoi.keyRemapShortcut"
        )
        #expect(RealBrightnessPersistence(defaults: defaults).loadKeyRemapShortcut() == .defaultShortcut)
    }

    @Test("after a failed decode, saving a new shortcut (one Settings row's worth) still leaves the original blob recoverable")
    func unreadableRecordSurvivesALaterSave() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let originalBytes = Data("not json".utf8)
        defaults.set(originalBytes, forKey: "com.ptlghost.BrightBoi.keyRemapShortcut")
        let persistence = RealBrightnessPersistence(defaults: defaults)

        #expect(persistence.loadKeyRemapShortcut() == nil)

        // Simulates editing one Settings row: the other half is built from
        // the in-memory F1/F2 fallback and saved, overwriting the main key.
        persistence.save(keyRemapShortcut: KeyRemapShortcut(raise: .f2, lower: .f1))

        #expect(defaults.data(forKey: "com.ptlghost.BrightBoi.keyRemapShortcut.unreadable") == originalBytes)
    }

    // MARK: Donation prompt dates

    @Test("the first-launch and last-prompt dates round-trip, and are nil when never saved")
    func donationDatesRoundTrip() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        let persistence = RealBrightnessPersistence(defaults: defaults)
        #expect(persistence.loadFirstLaunchDate() == nil)
        #expect(persistence.loadLastDonationPromptDate() == nil)

        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let last = Date(timeIntervalSince1970: 1_710_000_000)
        persistence.save(firstLaunchDate: first)
        persistence.save(lastDonationPromptDate: last)

        #expect(persistence.loadFirstLaunchDate() == first)
        #expect(persistence.loadLastDonationPromptDate() == last)
    }

    @Test("a wrong-typed stored donation date returns nil")
    func wrongTypedDonationDatesReturnNil() {
        let (name, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("yesterday", forKey: "com.ptlghost.BrightBoi.firstLaunchDate")
        defaults.set(42, forKey: "com.ptlghost.BrightBoi.lastDonationPromptDate")
        let persistence = RealBrightnessPersistence(defaults: defaults)
        #expect(persistence.loadFirstLaunchDate() == nil)
        #expect(persistence.loadLastDonationPromptDate() == nil)
    }
}
