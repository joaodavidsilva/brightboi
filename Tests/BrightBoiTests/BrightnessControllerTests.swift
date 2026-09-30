import AppKit
import Foundation
import Testing
@testable import BrightBoi

@MainActor
@Suite("BrightnessController")
struct BrightnessControllerTests {

    private struct Fixture {
        let controller: BrightnessController
        let displayBrightness: FakeDisplayBrightnessProvider
        let autoBrightnessToggle: FakeAutoBrightnessToggle
        let loginItemService: FakeLoginItemService
        let persistence: FakeBrightnessPersistence
        let keyTap: FakeKeyTap
        let powerSource: FakePowerSourceProvider
        let thermalState: FakeThermalStateProvider
        let bundleLocation: FakeBundleLocationProvider
        let displayAccessibility: FakeDisplayAccessibility
        let callLog: CallLog
        let scheduler: ManualPersistScheduler
    }

    private func makeFixture(
        storedPercentage: Double? = nil,
        persistenceDebounceInterval: TimeInterval = 0.3,
        supportsExtendedBrightness: Bool = true,
        isBuiltInDisplayAvailable: Bool = true,
        stubbedNominalControl: NominalControlStatus = .available,
        invertsColors: Bool = false,
        storedLaunchAtLoginEnabled: Bool? = nil,
        storedBoostCeiling: Double? = nil,
        storedKeyRemapEnabled: Bool? = nil,
        storedKeyRemapShortcut: KeyRemapShortcut? = nil,
        isOnBatteryPower: Bool = false,
        isLowPowerModeEnabled: Bool = false,
        stubbedThermalState: ProcessInfo.ThermalState = .nominal,
        storedHasCompletedOnboarding: Bool? = true,
        storedLastRegisteredLoginItemPath: String? = nil,
        stubbedLoginItemStatus: LoginItemStatus = .notRegistered,
        stubbedRegisterError: Error? = nil,
        stubbedUnregisterError: Error? = nil,
        bundlePath: String = "/Applications/BrightBoi.app",
        isInApplicationsFolder: Bool = true,
        isTranslocatedOrReadOnly: Bool = false,
        stubbedDisplayApplyOutcome: BrightnessApplyOutcome = .applied,
        stubbedCurrentNominalPercentage: Double? = nil,
        stubbedIsAutoBrightnessEnabled: Bool? = true,
        storedAutoBrightnessWasEnabledOriginally: Bool? = nil,
        storedAutoBrightnessTakeoverEnabled: Bool? = nil,
        startController: Bool = true
    ) -> Fixture {
        let callLog = CallLog()
        let displayBrightness = FakeDisplayBrightnessProvider()
        displayBrightness.stubbedSupportsExtendedBrightness = supportsExtendedBrightness
        displayBrightness.stubbedIsBuiltInDisplayAvailable = isBuiltInDisplayAvailable
        displayBrightness.stubbedNominalControl = stubbedNominalControl
        displayBrightness.stubbedOutcome = stubbedDisplayApplyOutcome
        displayBrightness.stubbedCurrentNominalPercentage = stubbedCurrentNominalPercentage
        displayBrightness.callLog = callLog
        let autoBrightnessToggle = FakeAutoBrightnessToggle()
        autoBrightnessToggle.stubbedIsAutoBrightnessEnabled = stubbedIsAutoBrightnessEnabled
        autoBrightnessToggle.callLog = callLog
        let loginItemService = FakeLoginItemService()
        loginItemService.stubbedStatus = stubbedLoginItemStatus
        loginItemService.stubbedRegisterError = stubbedRegisterError
        loginItemService.stubbedUnregisterError = stubbedUnregisterError
        let persistence = FakeBrightnessPersistence()
        persistence.storedPercentage = storedPercentage
        persistence.storedLaunchAtLoginEnabled = storedLaunchAtLoginEnabled
        persistence.storedBoostCeiling = storedBoostCeiling
        persistence.storedKeyRemapEnabled = storedKeyRemapEnabled
        persistence.storedKeyRemapShortcut = storedKeyRemapShortcut
        persistence.storedHasCompletedOnboarding = storedHasCompletedOnboarding
        persistence.storedLastRegisteredLoginItemPath = storedLastRegisteredLoginItemPath
        persistence.storedAutoBrightnessWasEnabledOriginally = storedAutoBrightnessWasEnabledOriginally
        persistence.storedAutoBrightnessTakeoverEnabled = storedAutoBrightnessTakeoverEnabled
        let keyTap = FakeKeyTap()
        let powerSource = FakePowerSourceProvider()
        powerSource.stubbedIsOnBatteryPower = isOnBatteryPower
        powerSource.stubbedIsLowPowerModeEnabled = isLowPowerModeEnabled
        let thermalState = FakeThermalStateProvider()
        thermalState.stubbedThermalState = stubbedThermalState
        let bundleLocation = FakeBundleLocationProvider()
        bundleLocation.bundlePath = bundlePath
        bundleLocation.isInApplicationsFolder = isInApplicationsFolder
        bundleLocation.isTranslocatedOrReadOnly = isTranslocatedOrReadOnly
        let displayAccessibility = FakeDisplayAccessibility()
        displayAccessibility.stubbedInvertsColors = invertsColors
        let scheduler = ManualPersistScheduler()

        let controller = BrightnessController(
            displayBrightness: displayBrightness,
            autoBrightnessToggle: autoBrightnessToggle,
            loginItemService: loginItemService,
            persistence: persistence,
            keyTap: keyTap,
            powerSource: powerSource,
            thermalState: thermalState,
            bundleLocation: bundleLocation,
            displayAccessibility: displayAccessibility,
            persistenceDebounceInterval: persistenceDebounceInterval,
            schedule: scheduler.schedule
        )
        if startController {
            controller.start()
        }

        return Fixture(
            controller: controller,
            displayBrightness: displayBrightness,
            autoBrightnessToggle: autoBrightnessToggle,
            loginItemService: loginItemService,
            persistence: persistence,
            keyTap: keyTap,
            powerSource: powerSource,
            thermalState: thermalState,
            bundleLocation: bundleLocation,
            displayAccessibility: displayAccessibility,
            callLog: callLog,
            scheduler: scheduler
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

    @Test("rounding to a grid point at or below 0 never produces a negative zero")
    func roundingNeverProducesNegativeZero() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(0)
        #expect(fixture.controller.currentState.percentage.sign == .plus)

        fixture.controller.setPercentage(2)
        #expect(fixture.controller.currentState.percentage.sign == .plus)
    }

    // MARK: Finite-value guards (NaN / infinity)

    @Test("setPercentage ignores NaN, leaving the current value untouched")
    func setPercentageIgnoresNaN() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        fixture.controller.setPercentage(.nan)
        #expect(fixture.controller.currentState.percentage == 50)
    }

    @Test("setPercentage ignores infinity")
    func setPercentageIgnoresInfinity() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        fixture.controller.setPercentage(.infinity)
        #expect(fixture.controller.currentState.percentage == 50)
    }

    @Test("a NaN stored percentage is discarded, adopting the display or the default instead of trapping the UI")
    func nanStoredPercentageIsDiscarded() {
        let fixture = makeFixture(storedPercentage: .nan, stubbedCurrentNominalPercentage: nil)
        #expect(fixture.controller.currentState.percentage == 100)
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

    @Test("auto-brightness is disabled before the first display apply, so corebrightnessd can't ramp over BrightBoi's own write")
    func disablesAutoBrightnessBeforeFirstApply() {
        let fixture = makeFixture(storedPercentage: 60)
        let disableIndex = fixture.callLog.entries.firstIndex(of: "disableAuto")
        let firstApplyIndex = fixture.callLog.entries.firstIndex { $0.hasPrefix("apply(") }
        #expect(disableIndex != nil)
        #expect(firstApplyIndex != nil)
        if let disableIndex, let firstApplyIndex {
            #expect(disableIndex < firstApplyIndex)
        }
    }

    @Test("nothing is applied at start when the percentage was adopted from the display, only disable")
    func adoptedPercentageSkipsInitialApply() {
        let fixture = makeFixture(storedPercentage: nil, stubbedCurrentNominalPercentage: 60)
        #expect(fixture.callLog.entries == ["disableAuto"])
    }

    // MARK: Auto-Brightness Takeover — recording and restoring the original

    @Test("the original auto-brightness setting is recorded once at start, before it's disabled")
    func recordsOriginalAutoBrightnessBeforeDisabling() {
        let fixture = makeFixture(stubbedIsAutoBrightnessEnabled: true)
        #expect(fixture.persistence.storedAutoBrightnessWasEnabledOriginally == true)
    }

    @Test("a second launch never overwrites the already-recorded original")
    func doesNotOverwriteRecordedOriginal() {
        let fixture = makeFixture(stubbedIsAutoBrightnessEnabled: false, storedAutoBrightnessWasEnabledOriginally: true)
        #expect(fixture.persistence.storedAutoBrightnessWasEnabledOriginally == true)
    }

    @Test("restoring on termination re-enables auto-brightness only when the recorded original was enabled")
    func restoresAutoBrightnessOnlyWhenOriginalWasEnabled() {
        let enabledFixture = makeFixture(storedAutoBrightnessWasEnabledOriginally: true)
        enabledFixture.controller.restoreSystemStateOnTermination()
        #expect(enabledFixture.autoBrightnessToggle.enableCallCount == 1)

        let disabledFixture = makeFixture(storedAutoBrightnessWasEnabledOriginally: false)
        disabledFixture.controller.restoreSystemStateOnTermination()
        #expect(disabledFixture.autoBrightnessToggle.enableCallCount == 0)
    }

    @Test("restoring on termination leaves macOS auto-brightness alone when the takeover is off")
    func restoreOnTerminationSkipsWhenTakeoverDisabled() {
        let fixture = makeFixture(storedAutoBrightnessWasEnabledOriginally: true, storedAutoBrightnessTakeoverEnabled: false)
        fixture.controller.restoreSystemStateOnTermination()
        #expect(fixture.autoBrightnessToggle.enableCallCount == 0)
        // The marker survives too — with the takeover off, this session
        // never disabled auto-brightness, so there's nothing to restore and
        // nothing to stop protecting.
        #expect(fixture.persistence.storedAutoBrightnessWasEnabledOriginally == true)
    }

    @Test("restoring on termination clears the recorded original so the next launch records a fresh one")
    func restoringOnTerminationClearsRecordedOriginal() {
        let fixture = makeFixture(storedAutoBrightnessWasEnabledOriginally: true)
        fixture.controller.restoreSystemStateOnTermination()
        #expect(fixture.persistence.storedAutoBrightnessWasEnabledOriginally == nil)
    }

    @Test("restoring on termination disengages Boost's gamma table when still boosted, without writing Nominal")
    func restoringOnTerminationDisengagesBoost() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(150)
        fixture.controller.restoreSystemStateOnTermination()
        #expect(fixture.displayBrightness.adoptExternalNominalCallCount == 1)
    }

    @Test("the Settings toggle turned off re-enables auto-brightness immediately, only if the original was enabled")
    func togglingTakeoverOffReenablesWhenOriginalWasEnabled() {
        let fixture = makeFixture(storedAutoBrightnessWasEnabledOriginally: true)
        fixture.controller.setAutoBrightnessTakeoverEnabled(false)
        #expect(fixture.autoBrightnessToggle.enableCallCount == 1)
        #expect(fixture.persistence.storedAutoBrightnessTakeoverEnabled == false)
        #expect(fixture.controller.currentState.autoBrightnessTakeoverEnabled == false)
    }

    @Test("the Settings toggle turned off does nothing when the original was already disabled")
    func togglingTakeoverOffDoesNothingWhenOriginalWasDisabled() {
        let fixture = makeFixture(storedAutoBrightnessWasEnabledOriginally: false)
        fixture.controller.setAutoBrightnessTakeoverEnabled(false)
        #expect(fixture.autoBrightnessToggle.enableCallCount == 0)
    }

    @Test("the Settings toggle turned back on disables auto-brightness again")
    func togglingTakeoverBackOnDisablesAgain() {
        let fixture = makeFixture()
        fixture.controller.setAutoBrightnessTakeoverEnabled(false)
        let disableCountAfterOff = fixture.autoBrightnessToggle.disableCallCount
        fixture.controller.setAutoBrightnessTakeoverEnabled(true)
        #expect(fixture.autoBrightnessToggle.disableCallCount == disableCountAfterOff + 1)
        #expect(fixture.controller.currentState.autoBrightnessTakeoverEnabled == true)
    }

    @Test("with the takeover switched off before start, auto-brightness is never disabled at launch")
    func takeoverDisabledSkipsDisableAtStart() {
        let fixture = makeFixture(storedAutoBrightnessTakeoverEnabled: false)
        #expect(fixture.autoBrightnessToggle.disableCallCount == 0)
    }

    @Test("autoBrightnessUnavailable is set once start() finds the private symbol couldn't be loaded")
    func flagsAutoBrightnessUnavailable() {
        let fixture = makeFixture(stubbedIsAutoBrightnessEnabled: nil)
        #expect(fixture.controller.autoBrightnessUnavailable == true)
    }

    // MARK: External brightness sync (Control Center, native keys with Key Remap off, macOS dimming)

    @Test("a key press first syncs from the display: reading 30 while state is 80 lands a raise on 35")
    func keyPressSyncsFromDisplayFirst() {
        let fixture = makeFixture(storedPercentage: 80, stubbedCurrentNominalPercentage: 30)
        fixture.controller.handleKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 35)
    }

    @Test("while boosted, a Nominal reading of 100 (BrightBoi's own write) is not treated as an external change")
    func boostedReadingOfOwnNominalWriteIsIgnored() {
        let fixture = makeFixture(storedPercentage: 150, stubbedCurrentNominalPercentage: 100)
        fixture.controller.syncFromDisplay()
        #expect(fixture.controller.currentState.percentage == 150)
        #expect(fixture.controller.currentState.isBoosted == true)
        #expect(fixture.displayBrightness.adoptExternalNominalCallCount == 0)
    }

    @Test("while boosted, a real external drop to 30 adopts it, disengages Boost once, and persists it")
    func boostedExternalDropAdoptsAndDisengages() {
        let fixture = makeFixture(storedPercentage: 150, stubbedCurrentNominalPercentage: 30)
        fixture.controller.syncFromDisplay()
        #expect(fixture.controller.currentState.percentage == 30)
        #expect(fixture.controller.currentState.isBoosted == false)
        #expect(fixture.displayBrightness.adoptExternalNominalCallCount == 1)

        fixture.controller.flushPendingPersist()
        #expect(fixture.persistence.savedPercentages == [30])
    }

    @Test("nothing changes when the display can't be read")
    func syncDoesNothingWhenDisplayUnreadable() {
        let fixture = makeFixture(storedPercentage: 80, stubbedCurrentNominalPercentage: nil)
        fixture.controller.syncFromDisplay()
        #expect(fixture.controller.currentState.percentage == 80)
    }

    @Test("a reading within tolerance of the current value is not treated as a change")
    func syncIgnoresReadingWithinTolerance() {
        let fixture = makeFixture(storedPercentage: 80, stubbedCurrentNominalPercentage: 82)
        fixture.controller.syncFromDisplay()
        #expect(fixture.controller.currentState.percentage == 80)
    }

    // MARK: Drag-path dedupe (the slider's DragGesture)

    @Test("a drag update that resolves to the current value produces no extra display apply")
    func dragUpdateToCurrentValueSkipsApply() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        let countBefore = fixture.displayBrightness.appliedPercentages.count
        // 51 and 52 both resolve to 50 on the 5% grid.
        fixture.controller.setPercentageFromDrag(51)
        fixture.controller.setPercentageFromDrag(52)
        #expect(fixture.displayBrightness.appliedPercentages.count == countBefore)
        #expect(fixture.controller.currentState.percentage == 50)
    }

    @Test("a drag update that resolves to a new value still applies")
    func dragUpdateToNewValueStillApplies() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        fixture.controller.setPercentageFromDrag(60)
        #expect(fixture.controller.currentState.percentage == 60)
        #expect(fixture.displayBrightness.appliedPercentages.last == 60)
    }

    @Test("setPercentageFromDrag ignores NaN")
    func dragUpdateIgnoresNaN() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        fixture.controller.setPercentageFromDrag(.nan)
        #expect(fixture.controller.currentState.percentage == 50)
    }

    @Test("a quick-set tap for the current value still re-applies it — the user's only way to resync after an outside change")
    func quickSetForCurrentValueStillApplies() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        let countBefore = fixture.displayBrightness.appliedPercentages.count
        fixture.controller.setPercentage(50)
        #expect(fixture.displayBrightness.appliedPercentages.count == countBefore + 1)
    }

    @Test("exactly one save happens after the debounce, even if quitting flushes right after")
    func exactlyOneSaveAfterDebounceThenTermination() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(60)
        fixture.scheduler.fire()
        #expect(fixture.persistence.savedPercentages == [60])

        fixture.controller.flushPendingPersist()
        #expect(fixture.persistence.savedPercentages == [60])
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

    // MARK: onKeyPress notification (HUD hook)

    @Test("onKeyPress fires with the press direction and the state right after it, on every handled key press")
    func onKeyPressFiresWithDirection() {
        let fixture = makeFixture()
        var received: [BrightnessController.KeyPress] = []
        fixture.controller.onKeyPress = { press, _ in received.append(press) }

        fixture.controller.handleKeyPress(.raise)
        fixture.controller.handleKeyPress(.lower)

        #expect(received == [.raise, .lower])
    }

    @Test("onKeyPress's state argument matches currentState right after the press")
    func onKeyPressStateMatchesCurrentState() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        var receivedState: BrightnessController.State?
        fixture.controller.onKeyPress = { _, state in receivedState = state }

        fixture.controller.handleKeyPress(.raise)

        #expect(receivedState == fixture.controller.currentState)
    }

    @Test("onKeyPress still fires when the press clamps at a boundary and the percentage doesn't change")
    func onKeyPressFiresEvenWhenClampedAtBoundary() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(200)
        var receivedCount = 0
        fixture.controller.onKeyPress = { _, _ in receivedCount += 1 }

        fixture.controller.handleKeyPress(.raise)

        #expect(fixture.controller.currentState.percentage == 200)
        #expect(receivedCount == 1)
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

    @Test("adopts the current display brightness when nothing is persisted, instead of jumping to a fixed default")
    func adoptsDisplayBrightnessWhenNothingPersisted() {
        let fixture = makeFixture(storedPercentage: nil, stubbedCurrentNominalPercentage: 37)
        // 37 rounds to 35 on the 5% grid.
        #expect(fixture.controller.currentState.percentage == 35)
        #expect(fixture.displayBrightness.appliedPercentages.isEmpty)

        fixture.controller.flushPendingPersist()
        #expect(fixture.persistence.savedPercentages == [35])
    }

    @Test("adopts a genuine 0 from the display as-is — the panel is already there")
    func adoptsZeroFromDisplayAsIs() {
        let fixture = makeFixture(storedPercentage: nil, stubbedCurrentNominalPercentage: 0)
        #expect(fixture.controller.currentState.percentage == 0)
        #expect(fixture.displayBrightness.appliedPercentages.isEmpty)
    }

    @Test("falls back to 100% when nothing is persisted and the display can't be read either")
    func fallsBackTo100WhenDisplayCannotBeRead() {
        let fixture = makeFixture(storedPercentage: nil, stubbedCurrentNominalPercentage: nil)
        #expect(fixture.controller.currentState.percentage == 100)
        #expect(fixture.displayBrightness.appliedPercentages == [100])
    }

    @Test("a persisted 0% restores to the 10% floor, not a dark screen, at launch")
    func persistedZeroRestoresToFloor() {
        let fixture = makeFixture(storedPercentage: 0)
        #expect(fixture.controller.currentState.percentage == 10)
    }

    @Test("the display-adoption floor never applies — a low adopted reading is kept as found")
    func adoptionFloorNeverAppliesToDisplayReading() {
        let fixture = makeFixture(storedPercentage: nil, stubbedCurrentNominalPercentage: 3)
        #expect(fixture.controller.currentState.percentage == 5)
    }

    @Test("debounces persistence: rapid changes coalesce into a single save of the final value")
    func persistenceIsDebounced() {
        let fixture = makeFixture()

        fixture.controller.setPercentage(10)
        fixture.controller.setPercentage(20)
        fixture.controller.setPercentage(30)

        #expect(fixture.persistence.savedPercentages.isEmpty)

        // Only the last of the three scheduled saves is still pending — the
        // manual scheduler overwrites its captured closure on every
        // `schedulePersist` call, same as the real one coalescing three
        // `DispatchQueue.main.asyncAfter` calls down to one live timer.
        fixture.scheduler.fire()

        #expect(fixture.persistence.savedPercentages == [30])
    }

    @Test("flushPendingPersist saves immediately — called by AppDelegate.applicationWillTerminate, not a notification observer on the controller itself")
    func flushesPendingPersistOnTermination() {
        let fixture = makeFixture(persistenceDebounceInterval: 30)

        fixture.controller.setPercentage(42)
        #expect(fixture.persistence.savedPercentages.isEmpty)

        fixture.controller.flushPendingPersist()

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

    // MARK: Launch-at-login — location gating

    @Test("never registers while running from outside an Applications folder, and explains why")
    func doesNotRegisterOutsideApplicationsFolder() {
        let fixture = makeFixture(isInApplicationsFolder: false)
        #expect(fixture.loginItemService.registerCallCount == 0)
        #expect(fixture.controller.currentState.launchAtLoginEnabled == false)
        #expect(fixture.controller.currentState.launchAtLoginStatusMessage != nil)
    }

    @Test("never registers while translocated or read-only, even inside an Applications folder path")
    func doesNotRegisterWhileTranslocated() {
        let fixture = makeFixture(isTranslocatedOrReadOnly: true)
        #expect(fixture.loginItemService.registerCallCount == 0)
        #expect(fixture.controller.currentState.launchAtLoginStatusMessage != nil)
    }

    @Test("re-points the login item when the bundle path changed since it was last registered")
    func repointsLoginItemAfterBundleMoved() {
        let fixture = makeFixture(
            storedLastRegisteredLoginItemPath: "/Users/me/Downloads/BrightBoi.app",
            stubbedLoginItemStatus: .enabled,
            bundlePath: "/Applications/BrightBoi.app"
        )
        #expect(fixture.loginItemService.unregisterCallCount == 1)
        #expect(fixture.loginItemService.registerCallCount == 1)
        #expect(fixture.persistence.storedLastRegisteredLoginItemPath == "/Applications/BrightBoi.app")
    }

    @Test("does not re-point when the bundle path is unchanged")
    func doesNotRepointWhenPathUnchanged() {
        let fixture = makeFixture(
            storedLastRegisteredLoginItemPath: "/Applications/BrightBoi.app",
            stubbedLoginItemStatus: .enabled,
            bundlePath: "/Applications/BrightBoi.app"
        )
        #expect(fixture.loginItemService.unregisterCallCount == 0)
        #expect(fixture.loginItemService.registerCallCount == 0)
    }

    @Test("a login item that was registered before and is now gone is treated as a user removal, not re-registered")
    func respectsUserRemovalInsteadOfReregistering() {
        let fixture = makeFixture(
            storedLastRegisteredLoginItemPath: "/Applications/BrightBoi.app",
            stubbedLoginItemStatus: .notRegistered
        )
        #expect(fixture.loginItemService.registerCallCount == 0)
        #expect(fixture.persistence.storedLaunchAtLoginEnabled == false)
        #expect(fixture.controller.currentState.launchAtLoginEnabled == false)
    }

    @Test("never registered before and withheld by location earlier retries once the location is valid again")
    func retriesRegistrationWhenNeverRegisteredBefore() {
        let fixture = makeFixture(storedLastRegisteredLoginItemPath: nil, stubbedLoginItemStatus: .notRegistered)
        #expect(fixture.loginItemService.registerCallCount == 1)
        #expect(fixture.controller.currentState.launchAtLoginEnabled == true)
    }

    // MARK: Launch-at-login — real status, errors, approval

    @Test("requiresApproval shows the switch on with needsApproval set")
    func requiresApprovalShowsOnWithNeedsApproval() {
        let fixture = makeFixture(storedLastRegisteredLoginItemPath: "/Applications/BrightBoi.app", stubbedLoginItemStatus: .requiresApproval)
        #expect(fixture.controller.currentState.launchAtLoginEnabled == true)
        #expect(fixture.controller.currentState.launchAtLoginNeedsApproval == true)
    }

    @Test("a thrown registration error is surfaced and the switch reverts to off")
    func registrationErrorIsSurfacedAndSwitchRevertsOff() {
        let fixture = makeFixture(storedLaunchAtLoginEnabled: false)
        fixture.loginItemService.stubbedRegisterError = FakeLoginItemError(message: "could not register")
        fixture.controller.setLaunchAtLoginEnabled(true)
        #expect(fixture.controller.currentState.launchAtLoginEnabled == false)
        #expect(fixture.controller.currentState.launchAtLoginStatusMessage == "could not register")
    }

    @Test("refreshLaunchAtLoginStatus re-reads the real status, e.g. after the user removes the item while running")
    func refreshPicksUpRemovalWhileRunning() {
        let fixture = makeFixture(storedLastRegisteredLoginItemPath: "/Applications/BrightBoi.app", stubbedLoginItemStatus: .enabled)
        #expect(fixture.controller.currentState.launchAtLoginEnabled == true)

        fixture.loginItemService.stubbedStatus = .notRegistered
        fixture.controller.refreshLaunchAtLoginStatus()

        #expect(fixture.controller.currentState.launchAtLoginEnabled == false)
    }

    // MARK: Boost blocked by another app

    @Test("a boost-blocked outcome clamps the displayed percentage to 100 and flags boostBlockedByOtherApp")
    func boostBlockedClampsToNominalCeiling() {
        let fixture = makeFixture(stubbedDisplayApplyOutcome: .boostBlockedByOtherApp)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.currentState.percentage == 100)
        #expect(fixture.controller.currentState.isBoosted == false)
        #expect(fixture.controller.currentState.boostBlockedByOtherApp == true)
    }

    @Test("an applied outcome below 100% never sets boostBlockedByOtherApp")
    func appliedOutcomeBelowCeilingLeavesFlagClear() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)
        #expect(fixture.controller.currentState.boostBlockedByOtherApp == false)
    }

    @Test("a captureFailed outcome clamps the displayed percentage to 100 without flagging boostBlockedByOtherApp")
    func captureFailedClampsToNominalCeilingWithoutOtherAppFlag() {
        let fixture = makeFixture(stubbedDisplayApplyOutcome: .captureFailed)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.currentState.percentage == 100)
        #expect(fixture.controller.currentState.isBoosted == false)
        #expect(fixture.controller.currentState.boostBlockedByOtherApp == false)
    }

    @Test("a displayUnavailable outcome clamps the displayed percentage to 100 without flagging another app")
    func displayUnavailableClampsToNominalCeiling() {
        let fixture = makeFixture(stubbedDisplayApplyOutcome: .displayUnavailable)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.currentState.percentage == 100)
        #expect(fixture.controller.currentState.boostBlockedByOtherApp == false)
    }

    // MARK: Built-in display coming and going

    /// Flips what the fake display reports and fires its change callback, the
    /// way the real provider does when the display configuration changes.
    private func reconfigureDisplay(_ fixture: Fixture, available: Bool, supportsBoost: Bool) {
        fixture.displayBrightness.stubbedIsBuiltInDisplayAvailable = available
        fixture.displayBrightness.stubbedSupportsExtendedBrightness = supportsBoost
        fixture.displayBrightness.onDisplayConfigurationChange?()
    }

    @Test("the controller listens for display changes only once started")
    func displayChangeCallbackIsRegisteredByStart() {
        let fixture = makeFixture(startController: false)
        #expect(fixture.displayBrightness.onDisplayConfigurationChange == nil)
        fixture.controller.start()
        #expect(fixture.displayBrightness.onDisplayConfigurationChange != nil)
    }

    @Test("state reports the built-in display as available by default")
    func builtInDisplayAvailableByDefault() {
        let fixture = makeFixture()
        #expect(fixture.controller.currentState.builtInDisplayAvailable == true)
    }

    @Test("state reports an unavailable built-in display from the start")
    func builtInDisplayUnavailableAtInit() {
        let fixture = makeFixture(supportsExtendedBrightness: false, isBuiltInDisplayAvailable: false)
        #expect(fixture.controller.currentState.builtInDisplayAvailable == false)
        #expect(fixture.controller.currentState.supportsBoost == false)
    }

    @Test("losing the built-in display drops a boosted level to 100 without driving any display")
    func losingBuiltInDisplayClampsWithoutApplying() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(150)
        let appliedBefore = fixture.displayBrightness.appliedPercentages

        reconfigureDisplay(fixture, available: false, supportsBoost: false)

        #expect(fixture.controller.currentState.percentage == 100)
        #expect(fixture.controller.currentState.isBoosted == false)
        #expect(fixture.controller.currentState.supportsBoost == false)
        #expect(fixture.controller.currentState.builtInDisplayAvailable == false)
        #expect(fixture.displayBrightness.appliedPercentages == appliedBefore)
    }

    @Test("the saved level survives the built-in display being lost, and Boost comes back with it")
    func boostLevelSurvivesDisplayLossAndReturn() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(150)
        fixture.controller.flushPendingPersist()

        reconfigureDisplay(fixture, available: false, supportsBoost: false)
        fixture.controller.flushPendingPersist()
        #expect(fixture.persistence.storedPercentage == 150)

        reconfigureDisplay(fixture, available: true, supportsBoost: true)

        #expect(fixture.controller.currentState.percentage == 150)
        #expect(fixture.controller.currentState.isBoosted == true)
        #expect(fixture.controller.currentState.builtInDisplayAvailable == true)
        #expect(fixture.displayBrightness.appliedPercentages.last == 150)
        fixture.controller.flushPendingPersist()
        #expect(fixture.persistence.storedPercentage == 150)
    }

    @Test("a level restored below Boost because the session started without it comes back when Boost appears")
    func persistedBoostLevelReturnsWhenBoostAppears() {
        let fixture = makeFixture(storedPercentage: 150, supportsExtendedBrightness: false, isBuiltInDisplayAvailable: false)
        #expect(fixture.controller.currentState.percentage == 100)

        reconfigureDisplay(fixture, available: true, supportsBoost: true)

        #expect(fixture.controller.currentState.percentage == 150)
        #expect(fixture.displayBrightness.appliedPercentages.last == 150)
        #expect(fixture.persistence.storedPercentage == 150)
    }

    @Test("choosing a level while Boost is unavailable replaces the remembered Boost level")
    func deliberateChangeForgetsRememberedBoostLevel() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(150)
        reconfigureDisplay(fixture, available: false, supportsBoost: false)

        fixture.controller.setPercentage(60)
        reconfigureDisplay(fixture, available: true, supportsBoost: true)

        #expect(fixture.controller.currentState.percentage == 60)
    }

    @Test("a built-in display that returns without Boost support gets its current level re-applied")
    func returningNonBoostDisplayReappliesCurrentLevel() {
        let fixture = makeFixture(supportsExtendedBrightness: false, isBuiltInDisplayAvailable: false)
        fixture.controller.setPercentage(60)
        let appliedBefore = fixture.displayBrightness.appliedPercentages.count

        reconfigureDisplay(fixture, available: true, supportsBoost: false)

        #expect(fixture.displayBrightness.appliedPercentages.count == appliedBefore + 1)
        #expect(fixture.displayBrightness.appliedPercentages.last == 60)
        #expect(fixture.controller.currentState.supportsBoost == false)
    }

    @Test("a display change notification that changes nothing the controller reads does nothing")
    func unchangedDisplayConfigurationIsIgnored() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(150)
        let appliedBefore = fixture.displayBrightness.appliedPercentages

        fixture.displayBrightness.onDisplayConfigurationChange?()

        #expect(fixture.displayBrightness.appliedPercentages == appliedBefore)
        #expect(fixture.controller.currentState.percentage == 150)
    }

    @Test("the level restored when Boost returns is re-clamped to the Boost Ceiling")
    func returningBoostRespectsBoostCeiling() {
        let fixture = makeFixture(storedBoostCeiling: 150)
        fixture.controller.setPercentage(150)
        reconfigureDisplay(fixture, available: false, supportsBoost: false)
        fixture.controller.setBoostCeiling(120)

        reconfigureDisplay(fixture, available: true, supportsBoost: true)

        #expect(fixture.controller.currentState.percentage <= 120)
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
        #expect(fixture.persistence.storedBoostCeiling == 100)
    }

    @Test("setBoostCeiling never goes above 200%")
    func setBoostCeilingClampsToCeiling() {
        let fixture = makeFixture()
        fixture.controller.setBoostCeiling(250)
        #expect(fixture.controller.currentState.boostCeiling == 200)
        #expect(fixture.persistence.storedBoostCeiling == 200)
    }

    @Test("setBoostCeiling snaps an off-grid value to the nearest 5%, tie breaking down")
    func setBoostCeilingSnapsToGrid() {
        let fixture = makeFixture()
        fixture.controller.setBoostCeiling(142.5)
        #expect(fixture.controller.currentState.boostCeiling == 140)
    }

    @Test("an off-grid ceiling stored from a hand-edited default snaps to the grid on init, so setPercentage can't resolve above it")
    func offGridStoredCeilingSnapsOnInit() {
        let fixture = makeFixture(storedBoostCeiling: 138)
        #expect(fixture.controller.currentState.boostCeiling == 140)
        fixture.controller.setPercentage(200)
        #expect(fixture.controller.currentState.percentage == 140)
    }

    @Test("setBoostCeiling ignores NaN")
    func setBoostCeilingIgnoresNaN() {
        let fixture = makeFixture()
        fixture.controller.setBoostCeiling(.nan)
        #expect(fixture.controller.currentState.boostCeiling == 200)
    }

    @Test("a NaN stored ceiling is discarded, falling back to the default 200%")
    func nanStoredCeilingFallsBackToDefault() {
        let fixture = makeFixture(storedBoostCeiling: .nan)
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
        #expect(fixture.persistence.storedKeyRemapEnabled == false)

        fixture.controller.setKeyRemapEnabled(true)
        #expect(fixture.keyTap.startCallCount == 2)
        #expect(fixture.controller.currentState.keyRemapEnabled == true)
        #expect(fixture.persistence.storedKeyRemapEnabled == true)
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
        #expect(fixture.persistence.storedKeyRemapShortcut == newShortcut)
    }

    @Test("with a stored shortcut that fails to decode, init falls back to F1/F2 without ever saving it back")
    func undecodableStoredShortcutNeverGetsSavedBack() {
        // The fake's loadKeyRemapShortcut simply returns whatever's stored,
        // so `nil` here stands in for `RealBrightnessPersistence` having
        // failed to decode the on-disk blob (see `RealBrightnessPersistenceTests`
        // for that decode failure itself).
        let fixture = makeFixture(storedKeyRemapShortcut: nil)
        #expect(fixture.controller.currentState.keyRemapShortcut == .defaultShortcut)
        #expect(fixture.persistence.storedKeyRemapShortcut == nil)
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

    // MARK: Battery advisory

    @Test("battery advisory fires above the 170% threshold while on battery power")
    func batteryAdvisoryFiresAboveThresholdOnBattery() {
        let fixture = makeFixture(isOnBatteryPower: true)
        fixture.controller.setPercentage(175)
        #expect(fixture.controller.batteryAdvisoryVisible == true)
    }

    @Test("battery advisory does not fire at exactly the 170% threshold")
    func batteryAdvisoryDoesNotFireAtThreshold() {
        let fixture = makeFixture(isOnBatteryPower: true)
        fixture.controller.setPercentage(170)
        #expect(fixture.controller.batteryAdvisoryVisible == false)
    }

    @Test("battery advisory does not fire above 170% while plugged into power")
    func batteryAdvisoryDoesNotFireWhilePluggedIn() {
        let fixture = makeFixture(isOnBatteryPower: false)
        fixture.controller.setPercentage(180)
        #expect(fixture.controller.batteryAdvisoryVisible == false)
    }

    @Test("battery advisory threshold is absolute, not relative to a lowered Boost Ceiling")
    func batteryAdvisoryThresholdIsAbsolute() {
        let fixture = makeFixture(storedBoostCeiling: 160, isOnBatteryPower: true)
        fixture.controller.setPercentage(200)
        #expect(fixture.controller.currentState.percentage == 160)
        #expect(fixture.controller.batteryAdvisoryVisible == false)
    }

    // MARK: Thermal advisory

    @Test("thermal advisory is nil when not boosted, regardless of thermal state")
    func thermalAdvisoryNilWhenNotBoosted() {
        let fixture = makeFixture(stubbedThermalState: .critical)
        fixture.controller.setPercentage(50)
        #expect(fixture.controller.thermalAdvisory == nil)
    }

    @Test("thermal advisory is nil when boosted but thermal state is nominal")
    func thermalAdvisoryNilWhenNominal() {
        let fixture = makeFixture(stubbedThermalState: .nominal)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.thermalAdvisory == nil)
    }

    @Test("thermal advisory is nil when boosted but thermal state is fair")
    func thermalAdvisoryNilWhenFair() {
        let fixture = makeFixture(stubbedThermalState: .fair)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.thermalAdvisory == nil)
    }

    @Test("thermal advisory fires when boosted and serious, delivered % is requested minus 20")
    func thermalAdvisorySeriousHeuristic() {
        let fixture = makeFixture(stubbedThermalState: .serious)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.thermalAdvisory == .init(requestedPercentage: 150, deliveredPercentage: 130))
    }

    @Test("thermal advisory fires when boosted and critical, delivered % is requested minus 40")
    func thermalAdvisoryCriticalHeuristic() {
        let fixture = makeFixture(stubbedThermalState: .critical)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.thermalAdvisory == .init(requestedPercentage: 150, deliveredPercentage: 110))
    }

    @Test("the delivered estimate is floored at 100%, never claiming delivery below the Nominal ceiling")
    func thermalAdvisoryDeliveredFloorsAt100() {
        let critical = makeFixture(stubbedThermalState: .critical)
        critical.controller.setPercentage(105)
        #expect(critical.controller.thermalAdvisory == .init(requestedPercentage: 105, deliveredPercentage: 100))

        let critical180 = makeFixture(stubbedThermalState: .critical)
        critical180.controller.setPercentage(180)
        #expect(critical180.controller.thermalAdvisory == .init(requestedPercentage: 180, deliveredPercentage: 140))
    }

    // MARK: Advisories live-refresh without a brightness change

    @Test("the battery advisory flips live when the power source changes, with no setPercentage call")
    func batteryAdvisoryFlipsLiveOnPowerSourceChange() {
        let fixture = makeFixture(isOnBatteryPower: false)
        fixture.controller.setPercentage(185)
        #expect(fixture.controller.batteryAdvisoryVisible == false)

        fixture.powerSource.stubbedIsOnBatteryPower = true
        fixture.powerSource.simulateChange()
        #expect(fixture.controller.batteryAdvisoryVisible == true)
    }

    @Test("Observation fires when the battery advisory flips live")
    func observationFiresOnLiveBatteryChange() {
        let fixture = makeFixture(isOnBatteryPower: false)
        fixture.controller.setPercentage(185)
        nonisolated(unsafe) var fired = false
        withObservationTracking {
            _ = fixture.controller.isOnBatteryPower
        } onChange: {
            fired = true
        }
        fixture.powerSource.stubbedIsOnBatteryPower = true
        fixture.powerSource.simulateChange()
        #expect(fired == true)
    }

    @Test("the thermal advisory flips live when the thermal state changes, with no setPercentage call")
    func thermalAdvisoryFlipsLiveOnThermalStateChange() {
        let fixture = makeFixture(stubbedThermalState: .nominal)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.thermalAdvisory == nil)

        fixture.thermalState.stubbedThermalState = .critical
        fixture.thermalState.simulateChange()
        #expect(fixture.controller.thermalAdvisory != nil)
    }

    @Test("charge-level ticks on battery with no actual change don't re-notify Observation")
    func unchangedPowerStateDoesNotReNotify() {
        let fixture = makeFixture(isOnBatteryPower: true)
        nonisolated(unsafe) var notified = false
        withObservationTracking {
            _ = fixture.controller.isOnBatteryPower
        } onChange: {
            notified = true
        }
        // Same value as the stub was already seeded with — a charge-percentage
        // tick that doesn't flip on-battery/off-battery.
        fixture.powerSource.simulateChange()
        #expect(notified == false)
    }

    // MARK: Low Power Mode advisory

    @Test("boosted with Low Power Mode on shows the advisory, on either power source")
    func lowPowerModeAdvisoryVisibleWhileBoosted() {
        let fixture = makeFixture(isLowPowerModeEnabled: true)
        fixture.controller.setPercentage(120)
        #expect(fixture.controller.isLowPowerModeAdvisoryVisible == true)
    }

    @Test("at or below 100% with Low Power Mode on, no advisory shows")
    func lowPowerModeAdvisoryHiddenWhenNotBoosted() {
        let fixture = makeFixture(isLowPowerModeEnabled: true)
        fixture.controller.setPercentage(100)
        #expect(fixture.controller.isLowPowerModeAdvisoryVisible == false)
    }

    @Test("boosted, on battery, above 170%, with Low Power Mode on: only the Low Power Mode advisory shows")
    func onlyLowPowerModeAdvisoryShowsWhenBothConditionsHold() {
        let fixture = makeFixture(isOnBatteryPower: true, isLowPowerModeEnabled: true)
        fixture.controller.setPercentage(185)
        #expect(fixture.controller.isLowPowerModeAdvisoryVisible == true)
        #expect(fixture.controller.batteryAdvisoryVisible == false)
    }

    @Test("Low Power Mode toggling live updates the advisory without any brightness change")
    func lowPowerModeAdvisoryFlipsLiveOnToggle() {
        let fixture = makeFixture(isLowPowerModeEnabled: false)
        fixture.controller.setPercentage(120)
        #expect(fixture.controller.isLowPowerModeAdvisoryVisible == false)

        fixture.powerSource.stubbedIsLowPowerModeEnabled = true
        fixture.powerSource.simulateChange()
        #expect(fixture.controller.isLowPowerModeAdvisoryVisible == true)
    }

    @Test("Low Power Mode never clamps or pauses the slider")
    func lowPowerModeNeverClampsBrightness() {
        let fixture = makeFixture(isLowPowerModeEnabled: true)
        fixture.controller.setPercentage(190)
        #expect(fixture.controller.currentState.percentage == 190)
    }

    // MARK: Brightness keys and the built-in display

    @Test("a key press is taken and applied while the built-in display is active")
    func keyPressTakenWhileBuiltInDisplayActive() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(50)

        let taken = fixture.keyTap.simulateKeyPress(.raise)

        #expect(taken == true)
        #expect(fixture.controller.currentState.percentage == 55)
        #expect(fixture.displayBrightness.appliedPercentages.last == 55)
    }

    @Test("with the built-in display inactive a key press is declined and changes nothing")
    func keyPressDeclinedWhileBuiltInDisplayInactive() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(150)
        fixture.controller.flushPendingPersist()
        let appliedBefore = fixture.displayBrightness.appliedPercentages
        let savedBefore = fixture.persistence.savedPercentages
        var hudFired = false
        fixture.controller.onKeyPress = { _, _ in hudFired = true }

        // Lid closed: the display is gone, and the change notification has
        // not reached the controller yet.
        fixture.displayBrightness.stubbedIsBuiltInDisplayAvailable = false
        let taken = fixture.keyTap.simulateKeyPress(.raise)

        #expect(taken == false)
        #expect(fixture.controller.currentState.percentage == 150)
        #expect(fixture.displayBrightness.appliedPercentages == appliedBefore)
        fixture.controller.flushPendingPersist()
        #expect(fixture.persistence.savedPercentages == savedBefore)
        #expect(hudFired == false)
    }

    @Test("the keys are taken again once the built-in display is back, and the Boost level is re-applied")
    func keysResumeWhenBuiltInDisplayReturns() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(150)
        reconfigureDisplay(fixture, available: false, supportsBoost: false)
        #expect(fixture.keyTap.simulateKeyPress(.lower) == false)

        reconfigureDisplay(fixture, available: true, supportsBoost: true)
        #expect(fixture.displayBrightness.appliedPercentages.last == 150)

        #expect(fixture.keyTap.simulateKeyPress(.lower) == true)
        #expect(fixture.controller.currentState.percentage == 145)
    }

    // MARK: Nominal control

    @Test("Nominal control is available by default")
    func nominalControlAvailableByDefault() {
        let fixture = makeFixture()
        #expect(fixture.controller.currentState.nominalControlStatus == .available)
        #expect(fixture.controller.currentState.nominalControlAvailable == true)
    }

    @Test("state reports Nominal control unavailable when the provider says so")
    func nominalControlUnavailableFromProvider() {
        let fixture = makeFixture(stubbedNominalControl: .symbolMissing)
        #expect(fixture.controller.currentState.nominalControlAvailable == false)
        #expect(fixture.controller.currentState.nominalControlStatus == .symbolMissing)
    }

    @Test("a preset locking brightness shows up when the popover next reads the display")
    func nominalControlLockPickedUpOnSync() {
        let fixture = makeFixture()
        fixture.displayBrightness.stubbedNominalControl = .lockedBySystem

        fixture.controller.syncFromDisplay()

        #expect(fixture.controller.currentState.nominalControlStatus == .lockedBySystem)

        fixture.displayBrightness.stubbedNominalControl = .available
        fixture.controller.syncFromDisplay()
        #expect(fixture.controller.currentState.nominalControlAvailable == true)
    }

    @Test("a display change that only affects Nominal control updates the state without re-applying")
    func nominalControlChangeFromDisplayConfiguration() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(60)
        let appliedBefore = fixture.displayBrightness.appliedPercentages

        fixture.displayBrightness.stubbedNominalControl = .lockedBySystem
        fixture.displayBrightness.onDisplayConfigurationChange?()

        #expect(fixture.controller.currentState.nominalControlStatus == .lockedBySystem)
        #expect(fixture.displayBrightness.appliedPercentages == appliedBefore)
    }

    @Test("Nominal control status is worded for its cause")
    func nominalControlMessages() {
        #expect(BrightnessMenuContent.nominalControlMessage(for: .available) == nil)
        #expect(BrightnessMenuContent.nominalControlMessage(for: .symbolMissing)?.contains("macOS") == true)
        #expect(BrightnessMenuContent.nominalControlMessage(for: .lockedBySystem)?.contains("preset") == true)
    }

    // MARK: Invert Colors

    @Test("with Invert Colors on, a Boost level is chosen but the display stays at 100 and Boost is paused")
    func invertColorsPausesBoost() {
        let fixture = makeFixture(invertsColors: true)
        fixture.controller.setPercentage(150)
        fixture.controller.flushPendingPersist()

        #expect(fixture.controller.currentState.percentage == 150)
        #expect(fixture.controller.currentState.isBoostPaused == true)
        #expect(fixture.controller.currentState.isBoosted == false)
        #expect(fixture.displayBrightness.appliedPercentages.last == 100)
        #expect(fixture.displayBrightness.appliedPercentages.contains { $0 > 100 } == false)
        #expect(fixture.persistence.storedPercentage == 150)
    }

    @Test("a paused Boost reports what the display delivers as its nits")
    func pausedBoostNits() {
        let fixture = makeFixture(invertsColors: true)
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.currentState.nits == 500)
    }

    @Test("turning Invert Colors off brings Boost back without touching the slider")
    func invertColorsOffResumesBoost() {
        let fixture = makeFixture(invertsColors: true)
        fixture.controller.setPercentage(150)

        fixture.displayAccessibility.stubbedInvertsColors = false
        fixture.displayAccessibility.simulateChange()

        #expect(fixture.displayBrightness.appliedPercentages.last == 150)
        #expect(fixture.controller.currentState.isBoostPaused == false)
        #expect(fixture.controller.currentState.isBoosted == true)
        #expect(fixture.controller.currentState.percentage == 150)
    }

    @Test("turning Invert Colors on while boosted pauses Boost live")
    func invertColorsOnWhileBoostedPausesLive() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(150)
        #expect(fixture.controller.currentState.isBoosted == true)

        fixture.displayAccessibility.stubbedInvertsColors = true
        fixture.displayAccessibility.simulateChange()

        #expect(fixture.displayBrightness.appliedPercentages.last == 100)
        #expect(fixture.controller.currentState.isBoostPaused == true)
        #expect(fixture.controller.currentState.percentage == 150)
    }

    @Test("Invert Colors does not affect Nominal levels")
    func invertColorsLeavesNominalAlone() {
        let fixture = makeFixture(invertsColors: true)
        fixture.controller.setPercentage(60)
        #expect(fixture.displayBrightness.appliedPercentages.last == 60)
        #expect(fixture.controller.currentState.isBoostPaused == false)
    }

    @Test("a repeated accessibility notification that changes nothing does not re-apply")
    func unchangedInvertColorsIsIgnored() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(150)
        let appliedBefore = fixture.displayBrightness.appliedPercentages

        fixture.displayAccessibility.simulateChange()

        #expect(fixture.displayBrightness.appliedPercentages == appliedBefore)
    }

    @Test("a level restored at launch with Invert Colors on starts paused, not boosted")
    func restoredBoostLevelStartsPausedUnderInvert() {
        let fixture = makeFixture(storedPercentage: 150, invertsColors: true)
        #expect(fixture.controller.currentState.isBoostPaused == true)
        #expect(fixture.displayBrightness.appliedPercentages.contains { $0 > 100 } == false)
    }
}
