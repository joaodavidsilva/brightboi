import Foundation
import CoreGraphics
import Testing
@testable import BrightBoi

/// The pure decisions behind suspending Boost and watching the headroom.
@Suite("BoostSuspension")
struct BoostSuspensionTests {
    @Test("with no reason, the plan is the requested factor clamped to the headroom, with EDR on")
    func activePlan() {
        let suspension = BoostSuspension()
        #expect(suspension.plan(requestedFactor: 2.0, headroom: 3.2) == .init(factor: 2.0))
        #expect(suspension.plan(requestedFactor: 2.0, headroom: 1.2) == .init(factor: 1.2))
    }

    @Test("each reason suspends: the unscaled table and no EDR", arguments: BoostSuspendReason.allCases)
    func everyReasonSuspends(reason: BoostSuspendReason) {
        var suspension = BoostSuspension()
        suspension.set(reason, active: true)
        #expect(suspension.isSuspended)
        #expect(suspension.plan(requestedFactor: 2.0, headroom: 3.2) == .init(factor: 1))
    }

    @Test("a reason resumes Boost only when it is the last one")
    func resumesOnlyWhenEmpty() {
        var suspension = BoostSuspension()
        #expect(suspension.set(.screenSaver, active: true) == true)
        #expect(suspension.set(.screenLocked, active: true) == false)

        #expect(suspension.set(.screenSaver, active: false) == false)
        #expect(suspension.isSuspended)

        #expect(suspension.set(.screenLocked, active: false) == true)
        #expect(suspension.isSuspended == false)
    }

    @Test("setting a reason twice, or clearing one that is not set, changes nothing")
    func idempotentSets() {
        var suspension = BoostSuspension()
        suspension.set(.sessionInactive, active: true)
        #expect(suspension.set(.sessionInactive, active: true) == false)
        #expect(suspension.set(.overlayOccluded, active: false) == false)
        #expect(suspension.reasons == [.sessionInactive])
    }
}

@Suite("HeadroomStarvationMonitor")
struct HeadroomStarvationMonitorTests {
    @Test("healthy headroom never triggers")
    func healthy() {
        var monitor = HeadroomStarvationMonitor()
        for second in 0..<30 {
            #expect(monitor.shouldRequestAgain(now: TimeInterval(second), headroom: 3.2, wantsBoost: true) == false)
        }
    }

    @Test("headroom missing for the patience period triggers once, then waits out the retry interval")
    func missing() {
        var monitor = HeadroomStarvationMonitor()
        #expect(monitor.shouldRequestAgain(now: 0, headroom: 1.0, wantsBoost: true) == false)
        #expect(monitor.shouldRequestAgain(now: HeadroomStarvationMonitor.patience - 0.1, headroom: 1.0, wantsBoost: true) == false)
        #expect(monitor.shouldRequestAgain(now: HeadroomStarvationMonitor.patience, headroom: 1.0, wantsBoost: true) == true)
        #expect(monitor.shouldRequestAgain(now: HeadroomStarvationMonitor.patience + 1, headroom: 1.0, wantsBoost: true) == false)
        #expect(monitor.shouldRequestAgain(now: HeadroomStarvationMonitor.patience + HeadroomStarvationMonitor.retryInterval, headroom: 1.0, wantsBoost: true) == true)
    }

    @Test("headroom that comes back starts the count over")
    func recovers() {
        var monitor = HeadroomStarvationMonitor()
        _ = monitor.shouldRequestAgain(now: 0, headroom: 1.0, wantsBoost: true)
        _ = monitor.shouldRequestAgain(now: 2, headroom: 3.2, wantsBoost: true)
        #expect(monitor.shouldRequestAgain(now: 3, headroom: 1.0, wantsBoost: true) == false)
        #expect(monitor.shouldRequestAgain(now: 3 + HeadroomStarvationMonitor.patience - 0.1, headroom: 1.0, wantsBoost: true) == false)
    }

    @Test("nothing is wanted, nothing is asked")
    func notWanted() {
        var monitor = HeadroomStarvationMonitor()
        _ = monitor.shouldRequestAgain(now: 0, headroom: 1.0, wantsBoost: false)
        #expect(monitor.shouldRequestAgain(now: 100, headroom: 1.0, wantsBoost: false) == false)
    }
}

@Suite("ObservedHeadroom")
struct ObservedHeadroomTests {
    @Test("a reading counts only after it has held steady")
    func needsToSettle() {
        var observed = ObservedHeadroom()
        #expect(observed.record(headroom: 3.2, now: 0) == false)
        #expect(observed.record(headroom: 3.2, now: 1) == false)
        #expect(observed.maximum == nil)
        #expect(observed.record(headroom: 3.2, now: ObservedHeadroom.settleTime) == true)
        #expect(observed.maximum == 3.2)
    }

    @Test("a ramp passing through large values is not learned")
    func rampIsIgnored() {
        var observed = ObservedHeadroom()
        // The backlight is still rising: the headroom falls through 5.0, 4.4, 3.9, ...
        var now = 0.0
        for value in stride(from: 5.0, through: 3.3, by: -0.2) {
            #expect(observed.record(headroom: CGFloat(value), now: now) == false)
            now += 0.25
        }
        #expect(observed.maximum == nil)
    }

    @Test("a lower settled reading never lowers the maximum, and a higher one raises it")
    func maximumOnlyGrows() {
        var observed = ObservedHeadroom(maximum: 3.2)
        _ = observed.record(headroom: 1.5, now: 0)
        #expect(observed.record(headroom: 1.5, now: 5) == false)
        #expect(observed.maximum == 3.2)

        _ = observed.record(headroom: 4.0, now: 10)
        #expect(observed.record(headroom: 4.0, now: 12) == true)
        #expect(observed.maximum == 4.0)
    }

    @Test("readings with no headroom or that are not numbers are ignored")
    func ignoresNonsense() {
        var observed = ObservedHeadroom()
        #expect(observed.record(headroom: 1.0, now: 0) == false)
        #expect(observed.record(headroom: .nan, now: 5) == false)
        #expect(observed.maximum == nil)
        #expect(ObservedHeadroom(maximum: .infinity).maximum == nil)
        #expect(ObservedHeadroom(maximum: 0.5).maximum == nil)
    }
}

@Suite("DistinctCodeTracker")
struct DistinctCodeTrackerTests {
    @Test("a code is new once, until a success re-arms it")
    func reportsEachCodeOnce() {
        var tracker = DistinctCodeTracker()
        #expect(tracker.isNew(1000) == true)
        #expect(tracker.isNew(1000) == false)
        #expect(tracker.isNew(7) == true)
        tracker.reset()
        #expect(tracker.isNew(1000) == true)
    }
}

@Suite("NominalControlStatus")
struct NominalControlStatusTests {
    @Test("a missing set symbol wins over everything")
    func missingSymbol() {
        #expect(NominalControlStatus.resolve(hasSetSymbol: false, canChange: true) == .symbolMissing)
        #expect(NominalControlStatus.resolve(hasSetSymbol: false, canChange: nil) == .symbolMissing)
    }

    @Test("a display that cannot change brightness is locked")
    func locked() {
        #expect(NominalControlStatus.resolve(hasSetSymbol: true, canChange: false) == .lockedBySystem)
    }

    @Test("an unknown answer does not disable a control that may work")
    func unknownIsAvailable() {
        #expect(NominalControlStatus.resolve(hasSetSymbol: true, canChange: nil) == .available)
        #expect(NominalControlStatus.resolve(hasSetSymbol: true, canChange: true) == .available)
    }
}
