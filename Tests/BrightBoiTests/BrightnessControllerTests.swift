import AppKit
import Foundation
import Testing
@testable import BrightBoi

@Suite("BrightnessController")
struct BrightnessControllerTests {

    private struct Fixture {
        let controller: BrightnessController
        let displayBrightness: FakeDisplayBrightnessProvider
        let autoBrightnessToggle: FakeAutoBrightnessToggle
        let loginItemService: FakeLoginItemService
        let persistence: FakeBrightnessPersistence
        let keyTap: FakeKeyTap
    }

    private func makeFixture(
        storedPercentage: Double? = nil,
        persistenceDebounceInterval: TimeInterval = 0.3,
        supportsExtendedBrightness: Bool = true,
        storedLaunchAtLoginEnabled: Bool? = nil,
        storedBoostCeiling: Double? = nil,
        storedKeyRemapEnabled: Bool? = nil,
        storedKeyRemapShortcut: KeyRemapShortcut? = nil
    ) -> Fixture {
        let displayBrightness = FakeDisplayBrightnessProvider()
        displayBrightness.stubbedSupportsExtendedBrightness = supportsExtendedBrightness
        let autoBrightnessToggle = FakeAutoBrightnessToggle()
        let loginItemService = FakeLoginItemService()
        let persistence = FakeBrightnessPersistence()
        persistence.storedPercentage = storedPercentage
        persistence.storedLaunchAtLoginEnabled = storedLaunchAtLoginEnabled
        persistence.storedBoostCeiling = storedBoostCeiling
        persistence.storedKeyRemapEnabled = storedKeyRemapEnabled
        persistence.storedKeyRemapShortcut = storedKeyRemapShortcut
        let keyTap = FakeKeyTap()

        let controller = BrightnessController(
            displayBrightness: displayBrightness,
            autoBrightnessToggle: autoBrightnessToggle,
            loginItemService: loginItemService,
            persistence: persistence,
            keyTap: keyTap,
            persistenceDebounceInterval: persistenceDebounceInterval
        )

        return Fixture(
            controller: controller,
            displayBrightness: displayBrightness,
            autoBrightnessToggle: autoBrightnessToggle,
            loginItemService: loginItemService,
            persistence: persistence,
            keyTap: keyTap
        )
    }

    // MARK: Clamping

    @Test("clamps below the 0% floor")
    func clampsToFloor() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(-50)
        #expect(fixture.controller.currentState.percentage == 0)
    }

    @Test("clamps above the 200% Boost Ceiling")
    func clampsToCeiling() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(250)
        #expect(fixture.controller.currentState.percentage == 200)
    }

    // MARK: Nominal / Boost boundary

    @Test("100% is still Nominal, not Boosted")
    func nominalCeilingIsNotBoosted() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(100)
        #expect(fixture.controller.currentState.isBoosted == false)
    }

    @Test("just past 100% is Boosted")
    func justPastCeilingIsBoosted() {
        let fixture = makeFixture()
        // 100.01 no longer makes sense once every set percentage resolves to
        // a 5% step — 105 is the nearest reachable value above the boundary.
        fixture.controller.setPercentage(105)
        #expect(fixture.controller.currentState.isBoosted == true)
    }

    // MARK: Icon-fill fraction

    @Test("icon-fill fraction is derived from percentage, spanning the full 0...200 range")
    func iconFillFractionSpansFullRange() {
        let fixture = makeFixture()

        fixture.controller.setPercentage(0)
        #expect(fixture.controller.currentState.iconFillFraction == 0)

        fixture.controller.setPercentage(100)
        #expect(fixture.controller.currentState.iconFillFraction == 0.5)

        fixture.controller.setPercentage(200)
        #expect(fixture.controller.currentState.iconFillFraction == 1)
    }

    // MARK: XDR/Boost availability

    @Test("on a non-XDR Mac, setPercentage clamps to 100 and supportsBoost is false")
    func nonXDRMacClampsToNominalCeiling() {
        let fixture = makeFixture(supportsExtendedBrightness: false)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.currentState.percentage == 100)
        #expect(fixture.controller.currentState.supportsBoost == false)
        #expect(fixture.controller.currentState.isBoosted == false)
    }

    @Test("on an XDR Mac, today's 200% ceiling behavior is unchanged")
    func xdrMacKeepsBoostCeiling() {
        let fixture = makeFixture(supportsExtendedBrightness: true)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.currentState.percentage == 150)
        #expect(fixture.controller.currentState.supportsBoost == true)
        #expect(fixture.controller.currentState.isBoosted == true)
    }

    @Test("on a non-XDR Mac, the icon reads full at 100%, not half, since 100 is the entire reachable range")
    func nonXDRMacIconFillsCompletelyAtOwnCeiling() {
        let fixture = makeFixture(supportsExtendedBrightness: false)
        fixture.controller.setPercentage(100)
        #expect(fixture.controller.currentState.iconFillFraction == 1)
    }

    // MARK: 5% granularity

    @Test("setPercentage rounds to the nearest multiple of 5")
    func setPercentageRoundsToNearestFive() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(81)
        #expect(fixture.controller.currentState.percentage == 80)
    }

    @Test("setPercentage rounds a tie down to the lower multiple of 5")
    func setPercentageRoundsTieDown() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(137.5)
        #expect(fixture.controller.currentState.percentage == 135)
    }

    @Test("a key press from a 5-aligned value lands on the next multiple of 5")
    func keyPressFromAlignedValueRaisesToNextFive() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        fixture.controller.handleKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 55)
    }

    @Test("a key press from a 5-aligned value lands on the previous multiple of 5")
    func keyPressFromAlignedValueLowersToPreviousFive() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        fixture.controller.handleKeyPress(.lower)
        #expect(fixture.controller.currentState.percentage == 45)
    }

    // MARK: Auto-Brightness Takeover

    @Test("Takeover fires exactly once on controller start, not per setPercentage call")
    func takeoverFiresOnce() {
        let fixture = makeFixture()
        #expect(fixture.autoBrightnessToggle.disableCallCount == 1)

        fixture.controller.setPercentage(10)
        fixture.controller.setPercentage(50)
        fixture.controller.setPercentage(150)

        #expect(fixture.autoBrightnessToggle.disableCallCount == 1)
    }

    @Test("login item registration and the key tap also start exactly once on controller start")
    func loginItemAndKeyTapStartOnce() {
        let fixture = makeFixture()
        #expect(fixture.loginItemService.registerCallCount == 1)
        #expect(fixture.keyTap.startCallCount == 1)

        fixture.controller.setPercentage(50)

        #expect(fixture.loginItemService.registerCallCount == 1)
        #expect(fixture.keyTap.startCallCount == 1)
    }

    // MARK: Key Remap

    @Test("key press raises using the app's own step below 100%")
    func keyPressRaisesBelowCeiling() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        fixture.controller.handleKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 55)
    }

    @Test("key press lowers back across the 100% boundary into Nominal")
    func keyPressLowersAcrossBoundary() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(105)
        fixture.controller.handleKeyPress(.lower)
        #expect(fixture.controller.currentState.percentage == 100)
        #expect(fixture.controller.currentState.isBoosted == false)
    }

    @Test("key press raises across the 100% boundary into Boost")
    func keyPressRaisesAcrossBoundary() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(100)
        fixture.controller.handleKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 105)
        #expect(fixture.controller.currentState.isBoosted == true)
    }

    @Test("key press clamps at the 200% ceiling")
    func keyPressClampsAtCeiling() {
        let fixture = makeFixture()
        // Start already at the ceiling (not just near it) — with a 5%
        // granularity that evenly divides the 200% ceiling, a value one
        // step below (195) would land exactly on 200 without ever needing
        // to clamp. Only a raise from the ceiling itself exercises the
        // key press's own clamping, as opposed to setPercentage's.
        fixture.controller.setPercentage(200)
        fixture.controller.handleKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 200)
    }

    @Test("key press clamps at the 0% floor")
    func keyPressClampsAtFloor() {
        let fixture = makeFixture()
        // Same reasoning as the ceiling test above: start at the floor
        // itself so the assertion exercises the key press's own clamping.
        fixture.controller.setPercentage(0)
        fixture.controller.handleKeyPress(.lower)
        #expect(fixture.controller.currentState.percentage == 0)
    }

    @Test("a press reported by the key tap drives the controller the same way a direct call does")
    func keyTapReportedPressDrivesController() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        fixture.keyTap.simulateKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 55)
    }

    // MARK: Persistence

    @Test("restores the persisted percentage on re-initialization, simulating relaunch")
    func restoresPersistedValueOnInit() {
        // A pre-granularity persisted value (137.5) is rounded the same way
        // a live setPercentage call would be — down to 135.
        let fixture = makeFixture(storedPercentage: 137.5)
        #expect(fixture.controller.currentState.percentage == 135)
        #expect(fixture.controller.currentState.isBoosted == true)
    }

    @Test("with no persisted value, starts at 0%")
    func startsAtZeroWithNoPersistedValue() {
        let fixture = makeFixture(storedPercentage: nil)
        #expect(fixture.controller.currentState.percentage == 0)
    }

    @Test("debounces persistence: rapid changes coalesce into a single save of the final value")
    func persistenceIsDebounced() async throws {
        let fixture = makeFixture(persistenceDebounceInterval: 0.05)

        fixture.controller.setPercentage(10)
        fixture.controller.setPercentage(20)
        fixture.controller.setPercentage(30)

        #expect(fixture.persistence.savedPercentages.isEmpty)

        try await Task.sleep(for: .milliseconds(250))

        #expect(fixture.persistence.savedPercentages == [30])
    }

    @Test("flushes a pending debounced save immediately when the app is about to terminate")
    func flushesPendingPersistOnTermination() {
        let fixture = makeFixture(persistenceDebounceInterval: 30)

        fixture.controller.setPercentage(42)
        #expect(fixture.persistence.savedPercentages.isEmpty)

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        // 42 rounds to 40 before it's ever persisted.
        #expect(fixture.persistence.savedPercentages == [40])
    }

    // MARK: Launch-at-login preference

    @Test("with nothing persisted, still registers exactly once at init, matching today's unconditional behavior")
    func launchAtLoginDefaultsToRegisteredWhenNothingPersisted() {
        let fixture = makeFixture(storedLaunchAtLoginEnabled: nil)
        #expect(fixture.loginItemService.registerCallCount == 1)
        #expect(fixture.controller.currentState.launchAtLoginEnabled == true)
    }

    @Test("a persisted false skips registration entirely at init, without redundantly calling unregister")
    func launchAtLoginPersistedFalseSkipsRegistrationAtInit() {
        let fixture = makeFixture(storedLaunchAtLoginEnabled: false)
        #expect(fixture.loginItemService.registerCallCount == 0)
        #expect(fixture.loginItemService.unregisterCallCount == 0)
        #expect(fixture.controller.currentState.launchAtLoginEnabled == false)
    }

    @Test("setLaunchAtLoginEnabled(false) unregisters and persists false")
    func setLaunchAtLoginEnabledFalseUnregistersAndPersists() {
        let fixture = makeFixture()
        fixture.controller.setLaunchAtLoginEnabled(false)
        #expect(fixture.loginItemService.unregisterCallCount == 1)
        #expect(fixture.persistence.storedLaunchAtLoginEnabled == false)
        #expect(fixture.controller.currentState.launchAtLoginEnabled == false)
    }

    @Test("setLaunchAtLoginEnabled(true) registers and persists true")
    func setLaunchAtLoginEnabledTrueRegistersAndPersists() {
        // Persisted false means init skips registration, so the assertion
        // below exercises the live toggle path specifically, not init's.
        let fixture = makeFixture(storedLaunchAtLoginEnabled: false)
        fixture.controller.setLaunchAtLoginEnabled(true)
        #expect(fixture.loginItemService.registerCallCount == 1)
        #expect(fixture.persistence.storedLaunchAtLoginEnabled == true)
        #expect(fixture.controller.currentState.launchAtLoginEnabled == true)
    }

    // MARK: Boost Ceiling

    @Test("with nothing persisted, the Boost Ceiling defaults to 200%, matching today's fixed behavior")
    func boostCeilingDefaultsToOriginalCeiling() {
        let fixture = makeFixture()
        #expect(fixture.controller.currentState.boostCeiling == 200)
    }

    @Test("restores a persisted Boost Ceiling on init")
    func restoresPersistedBoostCeiling() {
        let fixture = makeFixture(storedBoostCeiling: 150)
        #expect(fixture.controller.currentState.boostCeiling == 150)
    }

    @Test("setBoostCeiling never goes below 100%")
    func setBoostCeilingClampsToFloor() {
        let fixture = makeFixture()
        fixture.controller.setBoostCeiling(50)
        #expect(fixture.controller.currentState.boostCeiling == 100)
    }

    @Test("setBoostCeiling never goes above 200%")
    func setBoostCeilingClampsToCeiling() {
        let fixture = makeFixture()
        fixture.controller.setBoostCeiling(250)
        #expect(fixture.controller.currentState.boostCeiling == 200)
    }

    @Test("lowering the Boost Ceiling below the current live brightness clamps brightness down immediately")
    func loweringBoostCeilingClampsBrightnessDown() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(180)
        fixture.controller.setBoostCeiling(120)
        #expect(fixture.controller.currentState.percentage == 120)
        #expect(fixture.controller.currentState.boostCeiling == 120)
        #expect(fixture.displayBrightness.appliedPercentages.last == 120)
    }

    @Test("raising the Boost Ceiling doesn't touch the current brightness")
    func raisingBoostCeilingLeavesBrightnessUntouched() {
        let fixture = makeFixture(storedBoostCeiling: 150)
        fixture.controller.setPercentage(140)
        fixture.controller.setBoostCeiling(200)
        #expect(fixture.controller.currentState.percentage == 140)
    }

    @Test("leaving the Boost Ceiling untouched preserves today's exact 200%-ceiling behavior")
    func untouchedBoostCeilingKeepsOriginalCeilingBehavior() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(250)
        #expect(fixture.controller.currentState.percentage == 200)
        #expect(fixture.controller.currentState.boostCeiling == 200)
    }

    @Test("a lowered Boost Ceiling clamps setPercentage/key presses, not just the ceiling change itself")
    func loweredBoostCeilingClampsSubsequentChanges() {
        let fixture = makeFixture()
        fixture.controller.setBoostCeiling(110)
        fixture.controller.setPercentage(180)
        #expect(fixture.controller.currentState.percentage == 110)

        fixture.controller.handleKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 110)
    }

    // MARK: Key Remap — persistence and defaults

    @Test("with nothing persisted, Key Remap defaults to enabled with the F1/F2 shortcut, matching today's behavior")
    func keyRemapDefaultsMatchOriginalBehavior() {
        let fixture = makeFixture()
        #expect(fixture.controller.currentState.keyRemapEnabled == true)
        #expect(fixture.controller.currentState.keyRemapShortcut == .defaultShortcut)
        #expect(fixture.keyTap.startCallCount == 1)
        #expect(fixture.keyTap.lastStartedRemap == .defaultShortcut)
    }

    @Test("restores a persisted Key Remap shortcut and enabled flag on init")
    func restoresPersistedKeyRemap() {
        let customShortcut = KeyRemapShortcut(
            raise: KeyCombo(modifiers: [.option, .shift], keyCode: 0x1E),
            lower: KeyCombo(modifiers: [.option, .shift], keyCode: 0x21)
        )
        let fixture = makeFixture(storedKeyRemapEnabled: false, storedKeyRemapShortcut: customShortcut)
        #expect(fixture.controller.currentState.keyRemapEnabled == false)
        #expect(fixture.controller.currentState.keyRemapShortcut == customShortcut)
        // Disabled at init, so the tap should never have been started.
        #expect(fixture.keyTap.startCallCount == 0)
    }

    // MARK: Key Remap — on/off toggle

    @Test("the on/off toggle drives exactly one stop/start pair on the key tap")
    func keyRemapToggleDrivesOneStopStartPair() {
        let fixture = makeFixture()
        #expect(fixture.keyTap.startCallCount == 1)
        #expect(fixture.keyTap.stopCallCount == 0)

        fixture.controller.setKeyRemapEnabled(false)
        #expect(fixture.keyTap.stopCallCount == 1)
        #expect(fixture.controller.currentState.keyRemapEnabled == false)

        fixture.controller.setKeyRemapEnabled(true)
        #expect(fixture.keyTap.startCallCount == 2)
        #expect(fixture.controller.currentState.keyRemapEnabled == true)
    }

    @Test("disabling the Key Remap stops key presses from driving the controller")
    func disablingKeyRemapStopsPressesFromDrivingController() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        fixture.controller.setKeyRemapEnabled(false)
        fixture.keyTap.simulateKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 50)
    }

    @Test("re-enabling the Key Remap lets key presses drive the controller again")
    func reenablingKeyRemapRestoresPresses() {
        let fixture = makeFixture()
        fixture.controller.setKeyRemapEnabled(false)
        fixture.controller.setKeyRemapEnabled(true)
        fixture.controller.setPercentage(50)
        fixture.keyTap.simulateKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 55)
    }

    // MARK: Key Remap — reconfiguring the shortcut

    @Test("changing the Key Remap shortcut restarts the tap with the new combo, when enabled")
    func changingShortcutRestartsTapWhenEnabled() {
        let fixture = makeFixture()
        let newShortcut = KeyRemapShortcut(
            raise: KeyCombo(modifiers: [.option, .shift], keyCode: 0x1E),
            lower: KeyCombo(modifiers: [.option, .shift], keyCode: 0x21)
        )
        fixture.controller.setKeyRemapShortcut(newShortcut)
        #expect(fixture.controller.currentState.keyRemapShortcut == newShortcut)
        #expect(fixture.keyTap.lastStartedRemap == newShortcut)
        #expect(fixture.keyTap.startCallCount == 2)
    }

    @Test("changing the Key Remap shortcut while disabled persists it without starting the tap")
    func changingShortcutWhileDisabledDoesNotStartTap() {
        let fixture = makeFixture(storedKeyRemapEnabled: false)
        let newShortcut = KeyRemapShortcut(
            raise: KeyCombo(modifiers: [.command], keyCode: 0x00),
            lower: KeyCombo(modifiers: [.command], keyCode: 0x01)
        )
        fixture.controller.setKeyRemapShortcut(newShortcut)
        #expect(fixture.keyTap.startCallCount == 0)
        #expect(fixture.controller.currentState.keyRemapShortcut == newShortcut)
        #expect(fixture.persistence.storedKeyRemapShortcut == newShortcut)
    }
}
