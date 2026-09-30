import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import BrightBoi

/// `BoostEngagement` against a fake display table, overlay, session and
/// clock: the re-validation after the events that drop Boost, the
/// suspension while the overlay is covered, and the learning of the panel's
/// headroom.
@MainActor
@Suite("BoostEngagement")
struct BoostEngagementTests {
    private func approximately(_ a: CGGammaValue, _ b: CGGammaValue, tolerance: CGGammaValue = 0.002) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: Engaging

    @Test("engaging writes the baseline scaled by the requested factor and asks for EDR")
    func engageScalesBaseline() {
        let harness = BoostHarness()
        #expect(harness.engagement.engage(boostFraction: 0.5) == .applied)
        #expect(approximately(harness.tables.liveFactor, 1.5))
        #expect(harness.overlay.edrRequested == true)
        #expect(harness.engagement.isEngaged == true)
        #expect(approximately(harness.engagement.effectiveFactor, 1.5))
    }

    @Test("the factor never passes the EDR headroom the display grants")
    func engageClampsToHeadroom() {
        let harness = BoostHarness()
        harness.headroom = 1.2
        harness.engagement.engage(boostFraction: 1.0)
        #expect(approximately(harness.tables.liveFactor, 1.2))
    }

    @Test("the factor follows the headroom as it ramps up")
    func factorFollowsHeadroom() {
        let harness = BoostHarness()
        harness.headroom = 1.0
        harness.engagement.engage(boostFraction: 1.0)
        #expect(approximately(harness.tables.liveFactor, 1.0))

        harness.headroom = 1.6
        harness.engagement.pollHeadroom()
        #expect(approximately(harness.tables.liveFactor, 1.6))

        harness.headroom = 3.2
        harness.engagement.pollHeadroom()
        #expect(approximately(harness.tables.liveFactor, 2.0))
    }

    @Test("disengaging restores the baseline and releases EDR")
    func disengageRestoresBaseline() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.engagement.disengage()
        #expect(harness.tables.live == FakeGammaTables.clamped(harness.baseline))
        #expect(harness.overlay.edrRequested == false)
        #expect(harness.engagement.isEngaged == false)
    }

    @Test("a failed capture touches nothing")
    func engageWithFailedCaptureTouchesNothing() {
        let harness = BoostHarness()
        harness.tables.failsCapture = true
        #expect(harness.engagement.engage(boostFraction: 1.0) == .captureFailed)
        #expect(harness.tables.writes.isEmpty)
        #expect(harness.overlay.edrRequested == false)
    }

    @Test("an overlay that cannot be mounted leaves the display untouched")
    func engageWithoutOverlayTouchesNothing() {
        let harness = BoostHarness()
        harness.overlayAvailable = false
        #expect(harness.engagement.engage(boostFraction: 1.0) == .displayUnavailable)
        #expect(harness.tables.writes.isEmpty)
        #expect(harness.engagement.isEngaged == false)
    }

    @Test("another process's boosted table blocks engaging")
    func engageRefusesForeignBooster() {
        let harness = BoostHarness(baseline: FakeGammaTables.identity().scaled(by: 1.8))
        #expect(harness.engagement.engage(boostFraction: 0.5) == .boostBlockedByOtherApp)
        #expect(harness.tables.writes.isEmpty)
    }

    // MARK: Re-applying after the events that drop Boost

    @Test(
        "each event that resets the table gets Boost back, without compounding the factor",
        arguments: [
            BoostSystemEvent.systemWake,
            .displaysWake,
            .sessionBecameActive,
            .displayProfileChanged,
            .screenSaverStopped,
            .screenUnlocked
        ]
    )
    func eventReassertsBoost(event: BoostSystemEvent) {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)

        // The system resets the table to the plain calibration.
        harness.tables.otherProcessWrites(harness.baseline)
        harness.engagement.handle(event)

        #expect(approximately(harness.tables.liveFactor, 1.5))
        // Nothing ratchets: more of the same events leave the factor alone.
        harness.engagement.handle(event)
        harness.engagement.handle(event)
        harness.clock.advance(by: 5)
        #expect(approximately(harness.tables.liveFactor, 1.5))
    }

    @Test("a reset that lands after the first re-check is caught by the later ones")
    func lateResetIsCaught() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)

        harness.engagement.handle(.displaysWake)
        #expect(harness.clock.pendingCount == BoostEngagement.reassertionDelays.count)

        // ColorSync finishes its own reset a moment after the notification.
        harness.clock.advance(by: 0.3)
        harness.tables.otherProcessWrites(harness.baseline)
        harness.clock.advance(by: 0.3)
        #expect(approximately(harness.tables.liveFactor, 1.5))

        harness.tables.otherProcessWrites(harness.baseline)
        harness.clock.advance(by: 2)
        #expect(approximately(harness.tables.liveFactor, 1.5))
    }

    @Test("a new event replaces the re-checks still pending from the last one")
    func newEventReplacesPendingRechecks() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)
        harness.engagement.handle(.displaysWake)
        harness.engagement.handle(.displaysWake)
        #expect(harness.clock.pendingCount == BoostEngagement.reassertionDelays.count)
    }

    @Test("events do nothing while Boost is off")
    func eventsWhileIdleDoNothing() {
        let harness = BoostHarness()
        harness.engagement.handle(.displaysWake)
        harness.engagement.handle(.screenSaverStarted)
        #expect(harness.tables.writes.isEmpty)
        #expect(harness.overlay.engageCount == 0)
    }

    @Test("a new profile that still looks plain becomes the baseline and is what a disengage restores")
    func newProfileBecomesBaseline() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)

        // The user changes the display profile: a plain table, slightly dimmer.
        let newProfile = FakeGammaTables.identity(peak: 0.9)
        harness.tables.otherProcessWrites(newProfile)
        harness.engagement.handle(.displayProfileChanged)
        #expect(approximately(harness.tables.liveFactor, 1.5 * 0.9, tolerance: 0.003))

        harness.engagement.disengage()
        #expect(harness.tables.live == FakeGammaTables.clamped(newProfile))
    }

    @Test("an unknown table with samples at the top is left alone, and disengaging does not overwrite it")
    func foreignTableIsLeftAlone() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)
        let writesBefore = harness.tables.writes.count

        let foreign = FakeGammaTables.identity().scaled(by: 1.7)
        harness.tables.otherProcessWrites(foreign)
        harness.engagement.handle(.systemWake)
        #expect(harness.tables.writes.count == writesBefore)

        harness.engagement.disengage()
        #expect(harness.tables.live == FakeGammaTables.clamped(foreign))
    }

    @Test("a display reconfiguration re-asserts Boost on the same display and releases it on a different one")
    func reconfigurationFollowsTheDisplay() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)

        harness.tables.otherProcessWrites(harness.baseline)
        harness.engagement.displayConfigurationChanged(displayID: BoostHarness.displayID)
        #expect(approximately(harness.tables.liveFactor, 1.5))

        harness.engagement.displayConfigurationChanged(displayID: nil)
        #expect(harness.engagement.isEngaged == false)
        #expect(harness.overlay.edrRequested == false)
        #expect(harness.engagement.displayID == nil)
    }

    @Test("re-asserting re-homes the overlay")
    func reassertRehomesOverlay() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)
        let before = harness.overlay.rehomeCount
        harness.engagement.handle(.displaysWake)
        #expect(harness.overlay.rehomeCount > before)
    }

    @Test("a space change re-homes the overlay without touching the table")
    func spaceChangeRehomesOverlay() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)
        let writes = harness.tables.writes.count
        let before = harness.overlay.rehomeCount
        harness.engagement.handle(.spaceChanged)
        #expect(harness.overlay.rehomeCount == before + 1)
        #expect(harness.tables.writes.count == writes)
    }

    // MARK: Suspension

    @Test(
        "each reason that covers the overlay writes the unscaled baseline and releases EDR",
        arguments: [
            BoostSystemEvent.screenSaverStarted,
            .screenLocked,
            .sessionResignedActive
        ]
    )
    func reasonSuspendsBoost(event: BoostSystemEvent) {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        #expect(approximately(harness.tables.liveFactor, 2.0))

        harness.engagement.handle(event)

        #expect(approximately(harness.tables.liveFactor, 1.0))
        #expect(harness.overlay.edrRequested == false)
        #expect(harness.engagement.suspension.isSuspended == true)
        #expect(harness.engagement.isEngaged == true)
    }

    @Test("the screen saver stopping while the screen is still locked stays suspended")
    func screenSaverStopWhileLockedStaysSuspended() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.engagement.handle(.screenSaverStarted)
        harness.engagement.handle(.screenLocked)
        harness.session.isScreenLocked = true

        harness.engagement.handle(.screenSaverStopped)
        harness.clock.advance(by: 5)

        #expect(approximately(harness.tables.liveFactor, 1.0))
        #expect(harness.overlay.edrRequested == false)

        harness.session.isScreenLocked = false
        harness.engagement.handle(.screenUnlocked)
        #expect(approximately(harness.tables.liveFactor, 2.0))
        #expect(harness.overlay.edrRequested == true)
    }

    @Test("Boost resumes when the last reason ends")
    func resumeAfterLastReason() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)
        harness.engagement.handle(.sessionResignedActive)
        #expect(approximately(harness.tables.liveFactor, 1.0))

        harness.engagement.handle(.sessionBecameActive)
        #expect(approximately(harness.tables.liveFactor, 1.5))
        #expect(harness.overlay.edrRequested == true)
    }

    @Test("a factor change while suspended writes only the unscaled table and takes effect on resume")
    func factorChangeWhileSuspended() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)
        harness.session.isScreenSaverRunning = true
        harness.engagement.handle(.screenSaverStarted)
        let overlayEngages = harness.overlay.engageCount

        #expect(harness.engagement.engage(boostFraction: 1.0) == .applied)
        #expect(approximately(harness.tables.liveFactor, 1.0))
        #expect(harness.overlay.engageCount == overlayEngages)

        harness.session.isScreenSaverRunning = false
        harness.engagement.handle(.screenSaverStopped)
        #expect(approximately(harness.tables.liveFactor, 2.0))
    }

    @Test("engaging during a suspension mounts nothing and holds the baseline")
    func engageWhileSuspendedHoldsBaseline() {
        let harness = BoostHarness()
        harness.session.isScreenSaverRunning = true
        #expect(harness.engagement.engage(boostFraction: 1.0) == .applied)
        #expect(harness.overlayMountCount == 0)
        #expect(approximately(harness.tables.liveFactor, 1.0))
        #expect(harness.engagement.isEngaged == true)

        harness.session.isScreenSaverRunning = false
        harness.engagement.handle(.screenSaverStopped)
        #expect(approximately(harness.tables.liveFactor, 2.0))
    }

    @Test("resuming writes the factor the headroom allows, not the one asked for")
    func resumeClampsToHeadroom() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.engagement.handle(.screenLocked)

        // The headroom has not come back yet when the screen unlocks.
        harness.headroom = 1.0
        harness.engagement.handle(.screenUnlocked)
        #expect(approximately(harness.tables.liveFactor, 1.0))

        harness.headroom = 1.4
        harness.engagement.pollHeadroom()
        #expect(approximately(harness.tables.liveFactor, 1.4))

        harness.headroom = 3.2
        harness.engagement.pollHeadroom()
        #expect(approximately(harness.tables.liveFactor, 2.0))
    }

    @Test("a foreign table written during a suspension is neither overwritten on suspend nor on resume")
    func foreignTableDuringSuspensionSurvives() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)
        let foreign = FakeGammaTables.identity().scaled(by: 1.7)
        harness.tables.otherProcessWrites(foreign)

        harness.engagement.handle(.screenSaverStarted)
        harness.engagement.handle(.screenSaverStopped)

        #expect(harness.tables.live == FakeGammaTables.clamped(foreign))
    }

    @Test("a missed stop notification is repaired by reading the session back")
    func missedStopIsReconciled() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.engagement.handle(.screenSaverStarted)
        #expect(harness.engagement.suspension.isSuspended == true)

        // No `didstop` ever arrives, but the session is plainly idle again.
        harness.session = .idle
        harness.engagement.handle(.displaysWake)

        #expect(harness.engagement.suspension.isSuspended == false)
        #expect(approximately(harness.tables.liveFactor, 2.0))
    }

    @Test("the session snapshot alone can suspend Boost when a start notification was missed")
    func missedStartIsReconciled() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.session.isScreenLocked = true
        harness.engagement.handle(.systemWake)
        #expect(harness.engagement.suspension.contains(.screenLocked))
        #expect(approximately(harness.tables.liveFactor, 1.0))
    }

    @Test("a closed lid suspends Boost and writes nothing to the dark panel")
    func inactiveDisplaySuspendsWithoutWriting() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        let writes = harness.tables.writes.count

        harness.displayActive = false
        harness.engagement.displayConfigurationChanged(displayID: BoostHarness.displayID)

        #expect(harness.engagement.suspension.contains(.displayInactive))
        #expect(harness.overlay.edrRequested == false)
        #expect(harness.tables.writes.count == writes)

        harness.displayActive = true
        harness.engagement.displayConfigurationChanged(displayID: BoostHarness.displayID)
        #expect(harness.engagement.suspension.isSuspended == false)
        #expect(approximately(harness.tables.liveFactor, 2.0))
        #expect(harness.overlay.edrRequested == true)
    }

    @Test("a lid closed while Boost is off leaves no stale reason behind")
    func inactiveDisplayWhileIdleIsForgotten() {
        let harness = BoostHarness()
        harness.displayActive = false
        harness.engagement.displayConfigurationChanged(displayID: BoostHarness.displayID)
        harness.displayActive = true
        harness.engagement.displayConfigurationChanged(displayID: BoostHarness.displayID)

        harness.engagement.engage(boostFraction: 1.0)
        #expect(approximately(harness.tables.liveFactor, 2.0))
    }

    // MARK: Overlay occlusion

    @Test("an overlay that loses visibility is brought to the front once, then Boost is suspended if it stays covered")
    func occludedOverlayIsRecoveredThenSuspended() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)

        harness.overlay.setVisible(false)
        #expect(harness.overlay.bringToFrontCount == 1)
        #expect(harness.engagement.suspension.isSuspended == false)

        harness.clock.advance(by: BoostEngagement.occlusionGrace + 0.1)
        #expect(harness.engagement.suspension.contains(.overlayOccluded))
        #expect(approximately(harness.tables.liveFactor, 1.0))
        #expect(harness.overlay.edrRequested == false)

        harness.overlay.setVisible(true)
        #expect(harness.engagement.suspension.isSuspended == false)
        #expect(approximately(harness.tables.liveFactor, 2.0))
        #expect(harness.overlay.edrRequested == true)
    }

    @Test("an overlay that becomes visible again after being brought to the front is not suspended")
    func recoveredOverlayIsNotSuspended() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)

        harness.overlay.setVisible(false)
        harness.overlay.setVisible(true)
        harness.clock.advance(by: 2)

        #expect(harness.engagement.suspension.isSuspended == false)
        #expect(approximately(harness.tables.liveFactor, 2.0))
    }

    @Test("an occlusion left set by a released Boost does not hold the next engagement back")
    func staleOcclusionDoesNotSurviveDisengage() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.overlay.setVisible(false)
        harness.clock.advance(by: BoostEngagement.occlusionGrace + 0.1)
        #expect(harness.engagement.suspension.contains(.overlayOccluded))

        harness.engagement.disengage()
        harness.overlay.setVisible(true)
        harness.engagement.engage(boostFraction: 1.0)

        #expect(harness.engagement.suspension.isSuspended == false)
        #expect(approximately(harness.tables.liveFactor, 2.0))
        #expect(harness.overlay.edrRequested == true)
    }

    @Test("a missed 'visible again' notification is repaired while suspended")
    func missedVisibleNotificationIsRepaired() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.overlay.setVisible(false)
        harness.clock.advance(by: BoostEngagement.occlusionGrace + 0.1)
        #expect(harness.engagement.suspension.contains(.overlayOccluded))

        harness.overlay.isVisible = true
        harness.clock.advance(by: BoostEngagement.sessionRepairInterval + 0.1)
        harness.engagement.pollHeadroom()

        #expect(harness.engagement.suspension.isSuspended == false)
        #expect(approximately(harness.tables.liveFactor, 2.0))
    }

    @Test("a screen saver process that lingers after its stop notification does not leave Boost off")
    func lingeringScreenSaverIsRepaired() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.engagement.handle(.screenSaverStarted)

        harness.session.isScreenSaverRunning = true
        harness.engagement.handle(.screenSaverStopped)
        harness.clock.advance(by: 5)
        #expect(harness.engagement.suspension.contains(.screenSaver))

        harness.session.isScreenSaverRunning = false
        harness.clock.advance(by: BoostEngagement.sessionRepairInterval + 0.1)
        harness.engagement.pollHeadroom()

        #expect(harness.engagement.suspension.isSuspended == false)
        #expect(approximately(harness.tables.liveFactor, 2.0))
    }

    @Test("a resume that finds no screen yet is retried by the poll")
    func resumeWithoutScreenIsRetried() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.engagement.handle(.screenLocked)
        harness.overlay.rehomeSucceeds = false

        harness.engagement.handle(.screenUnlocked)
        #expect(approximately(harness.tables.liveFactor, 1.0))

        harness.overlay.rehomeSucceeds = true
        harness.engagement.pollHeadroom()
        #expect(approximately(harness.tables.liveFactor, 2.0))
        #expect(harness.overlay.edrRequested == true)
    }

    @Test("changing the level while Boost runs does not read the session back")
    func levelChangesDoNotScanTheSession() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 0.5)
        let reads = harness.sessionReadCount

        for fraction in stride(from: 0.5, through: 1.0, by: 0.1) {
            harness.engagement.engage(boostFraction: fraction)
        }
        #expect(harness.sessionReadCount == reads)
    }

    @Test("the overlay is not brought to the front while another reason holds")
    func noFightWithTheScreenSaver() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.engagement.handle(.screenSaverStarted)

        harness.overlay.setVisible(false)
        harness.clock.advance(by: 2)

        #expect(harness.overlay.bringToFrontCount == 0)
        #expect(harness.engagement.suspension.contains(.overlayOccluded) == false)
    }

    // MARK: Headroom

    @Test("headroom that stays missing gets the overlay asked for EDR again, but not continuously")
    func starvedHeadroomAsksAgain() {
        let harness = BoostHarness()
        harness.headroom = 1.0
        harness.engagement.engage(boostFraction: 1.0)
        let engagesAfterStart = harness.overlay.engageCount

        harness.engagement.pollHeadroom()
        harness.clock.advance(by: 1)
        harness.engagement.pollHeadroom()
        #expect(harness.overlay.engageCount == engagesAfterStart)

        harness.clock.advance(by: HeadroomStarvationMonitor.patience)
        harness.engagement.pollHeadroom()
        #expect(harness.overlay.engageCount == engagesAfterStart + 1)

        harness.clock.advance(by: 1)
        harness.engagement.pollHeadroom()
        #expect(harness.overlay.engageCount == engagesAfterStart + 1)

        harness.clock.advance(by: HeadroomStarvationMonitor.retryInterval)
        harness.engagement.pollHeadroom()
        #expect(harness.overlay.engageCount == engagesAfterStart + 2)
    }

    @Test("headroom that arrives in time never triggers a second request")
    func healthyHeadroomNeverAsksAgain() {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        let engages = harness.overlay.engageCount
        for _ in 0..<40 {
            harness.clock.advance(by: 0.25)
            harness.engagement.pollHeadroom()
        }
        #expect(harness.overlay.engageCount == engages)
    }

    @Test("a steady headroom is learned and saved, and sets the ceiling on a panel with less of it")
    func learnsHeadroomAndCapsTheCeiling() {
        let harness = BoostHarness()
        harness.headroom = 2.67
        harness.engagement.engage(boostFraction: 1.0)
        #expect(approximately(harness.engagement.effectiveFactor, 2.0))

        for _ in 0..<12 {
            harness.clock.advance(by: 0.25)
            harness.engagement.pollHeadroom()
        }

        #expect(harness.store.saves.count == 1)
        #expect(abs((harness.store.stored ?? 0) - 2.67) < 0.01)
        // 62.5% of 2.67 is a ratio of about 1.67, which is where 200% now lands.
        #expect(abs(harness.engagement.ceilingRatio - 1.67) < 0.01)
        harness.engagement.engage(boostFraction: 1.0)
        #expect(approximately(harness.tables.liveFactor, 1.67, tolerance: 0.01))
    }

    @Test("a stored headroom sets the ceiling from the very first engagement")
    func storedHeadroomSetsCeilingAtOnce() {
        let harness = BoostHarness(storedHeadroom: 2.4)
        harness.engagement.engage(boostFraction: 1.0)
        #expect(approximately(harness.tables.liveFactor, 1.5, tolerance: 0.01))
    }

    @Test("headroom seen while throttled does not lower the stored ceiling")
    func throttledHeadroomIsNotLearnedAsTheMaximum() {
        let harness = BoostHarness(storedHeadroom: 3.2)
        harness.headroom = 1.5
        harness.engagement.engage(boostFraction: 1.0)
        for _ in 0..<12 {
            harness.clock.advance(by: 0.25)
            harness.engagement.pollHeadroom()
        }
        #expect(harness.store.saves.isEmpty)
        #expect(harness.engagement.ceilingRatio == 2.0)
    }

    // MARK: Notification wiring

    @Test("the system notifications reach the engagement: the screen saver suspends, its end and a wake re-validate")
    func notificationsAreWired() async throws {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)

        harness.distributedCenter.post(name: Notification.Name("com.apple.screensaver.didstart"), object: nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.engagement.suspension.contains(.screenSaver))
        #expect(approximately(harness.tables.liveFactor, 1.0))

        harness.distributedCenter.post(name: Notification.Name("com.apple.screensaver.didstop"), object: nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.engagement.suspension.isSuspended == false)
        #expect(approximately(harness.tables.liveFactor, 2.0))

        harness.tables.otherProcessWrites(harness.baseline)
        harness.workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(approximately(harness.tables.liveFactor, 2.0))

        harness.engagement.disengage()
    }

    @Test("every event has a notification, on the center that carries it")
    func everyEventIsWired() {
        let wired = Set(BoostNotifications.all.map(\.event))
        let events: [BoostSystemEvent] = [
            .systemWake, .displaysWake, .sessionResignedActive, .sessionBecameActive,
            .screenSaverStarted, .screenSaverStopped, .screenLocked, .screenUnlocked,
            .displayProfileChanged, .spaceChanged
        ]
        for event in events {
            #expect(wired.contains(event))
        }
        let distributed = BoostNotifications.all.filter { $0.source == .distributed }.map(\.name.rawValue)
        #expect(distributed.contains("com.apple.screenIsLocked"))
        #expect(distributed.contains("com.apple.screenIsUnlocked"))
    }

    @Test("the application terminating disengages Boost")
    func terminationDisengages() async throws {
        let harness = BoostHarness()
        harness.engagement.engage(boostFraction: 1.0)
        harness.appCenter.post(name: NSApplication.willTerminateNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.engagement.isEngaged == false)
        #expect(harness.tables.live == FakeGammaTables.clamped(harness.baseline))
    }
}
