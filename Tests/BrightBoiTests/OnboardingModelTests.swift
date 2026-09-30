import Foundation
import Testing
@testable import BrightBoi

@MainActor
@Suite("OnboardingModel")
struct OnboardingModelTests {

    private struct Fixture {
        let model: OnboardingModel
        let persistence: FakeBrightnessPersistence
        let permissionsChecker: FakePermissionsChecker
        let openedURLs: OpenedURLs
    }

    private final class OpenedURLs {
        var urls: [URL] = []
    }

    private func makeFixture() -> Fixture {
        let persistence = FakeBrightnessPersistence()
        let permissionsChecker = FakePermissionsChecker()
        let openedURLs = OpenedURLs()
        let permissions = PermissionsModel(checker: permissionsChecker, openURL: { openedURLs.urls.append($0) })
        let model = OnboardingModel(persistence: persistence, permissions: permissions)
        return Fixture(model: model, persistence: persistence, permissionsChecker: permissionsChecker, openedURLs: openedURLs)
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
        #expect(fixture.persistence.storedHasCompletedOnboarding == nil)

        fixture.model.advance()
        #expect(fixture.model.step == .confirmation)
        #expect(fixture.persistence.storedHasCompletedOnboarding == true)
    }

    @Test("reaching the confirmation persists completion; the last button fires onFinished once")
    func completingAllThreeStepsPersists() {
        let fixture = makeFixture()
        var finishedCount = 0
        fixture.model.onFinished = { finishedCount += 1 }

        fixture.model.advance()
        fixture.model.advance()
        #expect(fixture.model.step == .confirmation)
        #expect(fixture.persistence.storedHasCompletedOnboarding == true)
        #expect(finishedCount == 0)

        fixture.model.advance()
        fixture.model.advance()

        #expect(fixture.model.step == .confirmation)
        #expect(finishedCount == 1)
        #expect(fixture.persistence.saveHasCompletedOnboardingCallCount == 1)
    }

    // MARK: Skip

    @Test("skipping goes to the confirmation, persists completion and does not finish")
    func skippingGoesToConfirmation() {
        let fixture = makeFixture()
        var finished = false
        fixture.model.onFinished = { finished = true }

        fixture.model.advance()
        fixture.model.skip()

        #expect(fixture.model.step == .confirmation)
        #expect(fixture.persistence.storedHasCompletedOnboarding == true)
        #expect(finished == false)

        fixture.model.advance()
        #expect(finished == true)
    }

    @Test("skipping only applies on the permissions step")
    func skipOutsidePermissionsIsIgnored() {
        let fixture = makeFixture()
        fixture.model.skip()
        #expect(fixture.model.step == .welcome)
        #expect(fixture.persistence.storedHasCompletedOnboarding == nil)
    }

    @Test("repeated skips and finishing never re-fire onFinished or re-save")
    func finishingIsIdempotent() {
        let fixture = makeFixture()
        var finishedCount = 0
        fixture.model.onFinished = { finishedCount += 1 }

        fixture.model.advance()
        fixture.model.skip()
        fixture.model.skip()
        fixture.model.advance()
        fixture.model.advance()

        #expect(finishedCount == 1)
        #expect(fixture.persistence.saveHasCompletedOnboardingCallCount == 1)
    }

    // MARK: Closing the window

    @Test("closing the window on any step persists completion without calling onFinished")
    func dismissedByClosePersists() {
        for advances in 0...2 {
            let fixture = makeFixture()
            var finished = false
            fixture.model.onFinished = { finished = true }
            for _ in 0..<advances { fixture.model.advance() }

            fixture.model.dismissedByClose()

            #expect(fixture.persistence.storedHasCompletedOnboarding == true)
            #expect(finished == false)
            #expect(OnboardingModel.shouldShow(persistence: fixture.persistence) == false)
        }
    }

    @Test("closing after a skip or after finishing does not save or finish again")
    func dismissedByCloseIsIdempotent() {
        let fixture = makeFixture()
        var finishedCount = 0
        fixture.model.onFinished = { finishedCount += 1 }

        fixture.model.advance()
        fixture.model.skip()
        fixture.model.dismissedByClose()
        fixture.model.dismissedByClose()
        #expect(fixture.persistence.saveHasCompletedOnboardingCallCount == 1)

        // The window closing after "Get bright" reports the close as well.
        let other = makeFixture()
        other.model.onFinished = { finishedCount += 1 }
        other.model.advance()
        other.model.advance()
        other.model.advance()
        other.model.dismissedByClose()
        #expect(finishedCount == 1)
        #expect(other.persistence.saveHasCompletedOnboardingCallCount == 1)
    }

    // MARK: Permission requests

    @Test("requesting Accessibility calls the permissions checker, not any alert")
    func requestsAccessibilityThroughChecker() {
        let fixture = makeFixture()
        fixture.permissionsChecker.stubbedAccessibilityGranted = false
        fixture.model.refreshPermissions()

        fixture.model.requestAccessibility()
        #expect(fixture.permissionsChecker.requestAccessibilityCallCount == 1)
        #expect(fixture.openedURLs.urls.isEmpty)
    }

    @Test("reads granted status at construction, matching the checker's status")
    func readsInitialGrantedStatus() {
        let persistence = FakeBrightnessPersistence()
        let permissionsChecker = FakePermissionsChecker()
        permissionsChecker.stubbedAccessibilityGranted = false

        let model = OnboardingModel(persistence: persistence, permissions: PermissionsModel(checker: permissionsChecker))

        #expect(model.accessibilityGranted == false)
        #expect(permissionsChecker.accessibilityQueryCount == 1)
    }

    @Test("refreshPermissions picks up a grant made in System Settings, without a second request")
    func refreshPicksUpGrantWithoutSecondRequest() {
        let fixture = makeFixture()
        fixture.permissionsChecker.stubbedAccessibilityGranted = false
        fixture.model.refreshPermissions()
        #expect(fixture.model.accessibilityGranted == false)

        fixture.model.requestAccessibility()
        fixture.permissionsChecker.stubbedAccessibilityGranted = true
        fixture.model.refreshPermissions()

        #expect(fixture.model.accessibilityGranted == true)
        #expect(fixture.permissionsChecker.requestAccessibilityCallCount == 1)
    }

    @Test("a second Grant click while still untrusted opens the Accessibility pane instead of prompting again")
    func secondGrantOpensPane() {
        let fixture = makeFixture()
        fixture.permissionsChecker.stubbedAccessibilityGranted = false
        fixture.model.refreshPermissions()

        fixture.model.requestAccessibility()
        fixture.model.requestAccessibility()

        #expect(fixture.permissionsChecker.requestAccessibilityCallCount == 1)
        #expect(fixture.openedURLs.urls == [PermissionsModel.accessibilityPaneURL])
    }
}
