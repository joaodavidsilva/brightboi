import Foundation
import Testing
@testable import BrightBoi

@MainActor
@Suite("PermissionsModel")
struct PermissionsModelTests {

    private final class Recorder {
        var openedURLs: [URL] = []
        var grants = 0
    }

    private struct Fixture {
        let model: PermissionsModel
        let checker: FakePermissionsChecker
        let recorder: Recorder
    }

    private func makeFixture(accessibility: Bool = false, inputMonitoring: PermissionAccess = .unknown) -> Fixture {
        let checker = FakePermissionsChecker()
        checker.stubbedAccessibilityGranted = accessibility
        checker.stubbedInputMonitoringAccess = inputMonitoring
        let recorder = Recorder()
        let model = PermissionsModel(checker: checker, openURL: { recorder.openedURLs.append($0) })
        model.addGrantObserver { recorder.grants += 1 }
        return Fixture(model: model, checker: checker, recorder: recorder)
    }

    // MARK: refresh

    @Test("reads both permissions once at construction")
    func readsEachPermissionAtConstruction() {
        let checker = FakePermissionsChecker()
        checker.stubbedAccessibilityGranted = true
        checker.stubbedInputMonitoringAccess = .denied

        let model = PermissionsModel(checker: checker)

        #expect(checker.accessibilityQueryCount == 1)
        #expect(checker.inputMonitoringQueryCount == 1)
        #expect(model.accessibilityGranted == true)
        #expect(model.inputMonitoring == .denied)
    }

    @Test("refresh shows a permission that was granted after construction")
    func refreshShowsNewGrant() {
        let fixture = makeFixture()
        #expect(fixture.model.accessibilityGranted == false)

        fixture.checker.stubbedAccessibilityGranted = true
        fixture.model.refresh()

        #expect(fixture.model.accessibilityGranted == true)
    }

    @Test("refresh shows a permission that was revoked")
    func refreshShowsRevocation() {
        let fixture = makeFixture(accessibility: true)
        fixture.checker.stubbedAccessibilityGranted = false
        fixture.model.refresh()
        #expect(fixture.model.accessibilityGranted == false)
    }

    @Test("refresh tells observers only when a permission is newly granted")
    func refreshNotifiesOnNewGrantOnly() {
        let fixture = makeFixture()

        fixture.model.refresh()
        #expect(fixture.recorder.grants == 0)

        fixture.checker.stubbedAccessibilityGranted = true
        fixture.model.refresh()
        #expect(fixture.recorder.grants == 1)

        fixture.model.refresh()
        #expect(fixture.recorder.grants == 1)

        fixture.checker.stubbedAccessibilityGranted = false
        fixture.model.refresh()
        #expect(fixture.recorder.grants == 1)
    }

    @Test("a newly granted Input Monitoring also notifies observers")
    func inputMonitoringGrantNotifies() {
        let fixture = makeFixture(accessibility: true, inputMonitoring: .denied)
        fixture.checker.stubbedInputMonitoringAccess = .granted
        fixture.model.refresh()
        #expect(fixture.recorder.grants == 1)
    }

    // MARK: requestOrOpenSettings

    @Test("the first Accessibility attempt shows the system prompt and opens nothing")
    func firstAccessibilityAttemptPrompts() {
        let fixture = makeFixture()
        fixture.model.requestOrOpenSettings(.accessibility)
        #expect(fixture.checker.requestAccessibilityCallCount == 1)
        #expect(fixture.recorder.openedURLs.isEmpty)
    }

    @Test("a later Accessibility attempt while untrusted opens the Accessibility pane only")
    func laterAccessibilityAttemptOpensPane() {
        let fixture = makeFixture()
        fixture.model.requestOrOpenSettings(.accessibility)
        fixture.model.requestOrOpenSettings(.accessibility)
        #expect(fixture.checker.requestAccessibilityCallCount == 1)
        #expect(fixture.recorder.openedURLs == [PermissionsModel.accessibilityPaneURL])
    }

    @Test("an Accessibility request does nothing once it is granted")
    func accessibilityRequestIgnoredWhenGranted() {
        let fixture = makeFixture(accessibility: true)
        fixture.model.requestOrOpenSettings(.accessibility)
        #expect(fixture.checker.requestAccessibilityCallCount == 0)
        #expect(fixture.recorder.openedURLs.isEmpty)
    }

    @Test("Input Monitoring that macOS has not asked about yet shows only the system prompt")
    func unknownInputMonitoringPromptsOnly() {
        let fixture = makeFixture(inputMonitoring: .unknown)
        fixture.model.requestOrOpenSettings(.inputMonitoring)
        #expect(fixture.checker.requestInputMonitoringCallCount == 1)
        #expect(fixture.recorder.openedURLs.isEmpty)
    }

    @Test("Input Monitoring that was turned down repeats the request and opens its pane")
    func deniedInputMonitoringOpensPane() {
        let fixture = makeFixture(inputMonitoring: .denied)
        fixture.model.requestOrOpenSettings(.inputMonitoring)
        #expect(fixture.checker.requestInputMonitoringCallCount == 1)
        #expect(fixture.recorder.openedURLs == [PermissionsModel.inputMonitoringPaneURL])
    }

    @Test("a granted Input Monitoring needs no request")
    func grantedInputMonitoringIgnored() {
        let fixture = makeFixture(inputMonitoring: .granted)
        fixture.model.requestOrOpenSettings(.inputMonitoring)
        #expect(fixture.checker.requestInputMonitoringCallCount == 0)
        #expect(fixture.recorder.openedURLs.isEmpty)
    }

    // MARK: needsInputMonitoring

    @Test("Input Monitoring is offered only when Accessibility is granted and the tap still is not running")
    func offersInputMonitoringOnlyWhenTapBlocked() {
        let blocked = makeFixture(accessibility: true, inputMonitoring: .denied)
        #expect(blocked.model.needsInputMonitoring(keyRemapEnabled: true, keyTapActive: false) == true)
        #expect(blocked.model.needsInputMonitoring(keyRemapEnabled: true, keyTapActive: true) == false)

        // With Key Remap off the tap is expected to be down, so nothing is offered.
        #expect(blocked.model.needsInputMonitoring(keyRemapEnabled: false, keyTapActive: false) == false)

        let noAccessibility = makeFixture(accessibility: false, inputMonitoring: .denied)
        #expect(noAccessibility.model.needsInputMonitoring(keyRemapEnabled: true, keyTapActive: false) == false)

        let granted = makeFixture(accessibility: true, inputMonitoring: .granted)
        #expect(granted.model.needsInputMonitoring(keyRemapEnabled: true, keyTapActive: false) == false)
    }
}
