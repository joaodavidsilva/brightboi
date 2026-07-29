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
        persistenceDebounceInterval: TimeInterval = 0.3
    ) -> Fixture {
        let displayBrightness = FakeDisplayBrightnessProvider()
        let autoBrightnessToggle = FakeAutoBrightnessToggle()
        let loginItemService = FakeLoginItemService()
        let persistence = FakeBrightnessPersistence()
        persistence.storedPercentage = storedPercentage
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
        fixture.controller.setPercentage(100.01)
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
        #expect(fixture.controller.currentState.percentage == 56.25)
    }

    @Test("key press lowers back across the 100% boundary into Nominal")
    func keyPressLowersAcrossBoundary() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(102)
        fixture.controller.handleKeyPress(.lower)
        #expect(fixture.controller.currentState.percentage == 95.75)
        #expect(fixture.controller.currentState.isBoosted == false)
    }

    @Test("key press raises across the 100% boundary into Boost")
    func keyPressRaisesAcrossBoundary() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(98)
        fixture.controller.handleKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 104.25)
        #expect(fixture.controller.currentState.isBoosted == true)
    }

    @Test("key press clamps at the 200% ceiling")
    func keyPressClampsAtCeiling() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(198)
        fixture.controller.handleKeyPress(.raise)
        #expect(fixture.controller.currentState.percentage == 200)
    }

    @Test("key press clamps at the 0% floor")
    func keyPressClampsAtFloor() {
        let fixture = makeFixture()
        fixture.controller.setPercentage(2)
        fixture.controller.handleKeyPress(.lower)
        #expect(fixture.controller.currentState.percentage == 0)
    }

    // MARK: Persistence

    @Test("restores the persisted percentage on re-initialization, simulating relaunch")
    func restoresPersistedValueOnInit() {
        let fixture = makeFixture(storedPercentage: 137.5)
        #expect(fixture.controller.currentState.percentage == 137.5)
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
}
