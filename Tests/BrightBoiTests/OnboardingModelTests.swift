import Testing
@testable import BrightBoi

@MainActor
@Suite("OnboardingModel")
struct OnboardingModelTests {

    private struct Fixture {
        let model: OnboardingModel
        let persistence: FakeBrightnessPersistence
        let permissionsChecker: FakePermissionsChecker
    }

    private func makeFixture(storedHasCompletedOnboarding: Bool? = nil) -> Fixture {
        let persistence = FakeBrightnessPersistence()
        persistence.storedHasCompletedOnboarding = storedHasCompletedOnboarding
        let permissionsChecker = FakePermissionsChecker()
        let model = OnboardingModel(persistence: persistence, permissionsChecker: permissionsChecker)
        return Fixture(model: model, persistence: persistence, permissionsChecker: permissionsChecker)
    }

    // MARK: shouldShow

    @Test("shows on a fresh install, where nothing has been persisted yet")
    func showsOnFreshInstall() {
        let persistence = FakeBrightnessPersistence()
        #expect(OnboardingModel.shouldShow(persistence: persistence) == true)
    }

    @Test("never shows again once the flag is persisted")
    func hiddenOnceCompleted() {
        let persistence = FakeBrightnessPersistence()
        persistence.storedHasCompletedOnboarding = true
        #expect(OnboardingModel.shouldShow(persistence: persistence) == false)
    }

    // MARK: Step flow

    @Test("advances welcome -> permissions -> confirmation, one step at a time")
    func advancesThroughSteps() {
        let fixture = makeFixture()
        #expect(fixture.model.step == .welcome)

        fixture.model.advance()
        #expect(fixture.model.step == .permissions)

        fixture.model.advance()
        #expect(fixture.model.step == .confirmation)
    }

    @Test("advancing past confirmation persists completion and fires onFinished")
    func completingAllThreeStepsPersists() {
        let fixture = makeFixture()
        var finished = false
        fixture.model.onFinished = { finished = true }

        fixture.model.advance()
        fixture.model.advance()
        fixture.model.advance()

        #expect(fixture.model.step == .confirmation)
        #expect(fixture.persistence.storedHasCompletedOnboarding == true)
        #expect(finished == true)
    }

    // MARK: Skip

    @Test("skipping from the permissions step persists completion and fires onFinished")
    func skippingPersists() {
        let fixture = makeFixture()
        var finished = false
        fixture.model.onFinished = { finished = true }

        fixture.model.advance()
        fixture.model.skip()

        #expect(fixture.persistence.storedHasCompletedOnboarding == true)
        #expect(finished == true)
    }

    @Test("skipping never re-fires onFinished or re-saves on a later call")
    func finishingIsIdempotent() {
        let fixture = makeFixture()
        var finishedCount = 0
        fixture.model.onFinished = { finishedCount += 1 }

        fixture.model.skip()
        fixture.model.skip()

        #expect(finishedCount == 1)
    }

    // MARK: Permission requests — replaces RealKeyTap's old alert path

    @Test("requesting Accessibility calls the permissions checker, not any alert")
    func requestsAccessibilityThroughChecker() {
        let fixture = makeFixture()
        fixture.model.requestAccessibility()
        #expect(fixture.permissionsChecker.requestAccessibilityCallCount == 1)
    }

    @Test("requesting Input Monitoring calls the permissions checker, not any alert")
    func requestsInputMonitoringThroughChecker() {
        let fixture = makeFixture()
        fixture.model.requestInputMonitoring()
        #expect(fixture.permissionsChecker.requestInputMonitoringCallCount == 1)
    }

    @Test("reads granted status once at construction, matching the checker's status")
    func readsInitialGrantedStatus() {
        let persistence = FakeBrightnessPersistence()
        let permissionsChecker = FakePermissionsChecker()
        permissionsChecker.stubbedAccessibilityGranted = false
        permissionsChecker.stubbedInputMonitoringGranted = true

        let model = OnboardingModel(persistence: persistence, permissionsChecker: permissionsChecker)

        #expect(model.accessibilityGranted == false)
        #expect(model.inputMonitoringGranted == true)
    }

    @Test("requesting a permission refreshes its granted status from the checker")
    func requestingRefreshesGrantedStatus() {
        let fixture = makeFixture()
        fixture.permissionsChecker.stubbedAccessibilityGranted = false

        fixture.model.requestAccessibility()
        #expect(fixture.model.accessibilityGranted == false)

        fixture.permissionsChecker.stubbedAccessibilityGranted = true
        fixture.model.requestAccessibility()
        #expect(fixture.model.accessibilityGranted == true)
    }
}
