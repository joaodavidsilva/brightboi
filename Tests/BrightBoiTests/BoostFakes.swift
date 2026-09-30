import CoreGraphics
import Foundation
@testable import BrightBoi

/// Fakes for `BoostEngagement`'s environment. Used exclusively in tests.

/// A display's transfer table that behaves like the real one: a read-back is
/// clamped at 1.0, and another process can replace it at any time.
@MainActor
final class FakeGammaTables: GammaTableAccessing {
    private(set) var live: GammaTable
    private(set) var writes: [GammaTable] = []
    var failsWrites = false
    var failsCapture = false

    init(live: GammaTable = FakeGammaTables.identity()) {
        self.live = Self.clamped(live)
    }

    static let sampleCount = 1024

    static func identity(peak: CGGammaValue = 1.0) -> GammaTable {
        let ramp = (0..<sampleCount).map { CGGammaValue($0) / CGGammaValue(sampleCount - 1) * peak }
        return GammaTable(red: ramp, green: ramp, blue: ramp)
    }

    static func clamped(_ table: GammaTable) -> GammaTable {
        GammaTable(red: table.red.map { min($0, 1) }, green: table.green.map { min($0, 1) }, blue: table.blue.map { min($0, 1) })
    }

    func capture(displayID: CGDirectDisplayID) -> GammaTable? {
        failsCapture ? nil : live
    }

    func apply(_ table: GammaTable, to displayID: CGDirectDisplayID) -> Bool {
        guard !failsWrites else { return false }
        writes.append(table)
        live = Self.clamped(table)
        return true
    }

    /// Another process (ColorSync after a wake, a calibration loader, a
    /// colour-temperature app) replacing the table behind BrightBoi's back.
    func otherProcessWrites(_ table: GammaTable) {
        live = Self.clamped(table)
    }

    /// The factor the live table is scaled by, read at mid-range where no
    /// clamping is involved.
    var liveFactor: CGGammaValue {
        let mid = live.red.count / 4
        return live.red[mid] / (CGGammaValue(mid) / CGGammaValue(live.red.count - 1))
    }
}

@MainActor
final class FakeOverlay: EDROverlaying {
    var isVisible = true
    var onVisibilityChange: (() -> Void)?
    private(set) var edrRequested = false
    private(set) var engageCount = 0
    private(set) var disengageCount = 0
    private(set) var bringToFrontCount = 0
    private(set) var rehomeCount = 0
    var rehomeSucceeds = true

    func rehome(to displayID: CGDirectDisplayID) -> Bool {
        rehomeCount += 1
        return rehomeSucceeds
    }

    func bringToFront() {
        bringToFrontCount += 1
    }

    func engageEDR() {
        edrRequested = true
        engageCount += 1
    }

    func disengageEDR() {
        edrRequested = false
        disengageCount += 1
    }

    /// Changes visibility and fires the callback, like the occlusion
    /// notification does.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        onVisibilityChange?()
    }
}

@MainActor
final class FakeHeadroomStore: ObservedHeadroomStoring {
    var stored: CGFloat?
    private(set) var saves: [CGFloat] = []

    func load(forDisplay displayID: CGDirectDisplayID) -> CGFloat? { stored }

    func save(_ headroom: CGFloat, forDisplay displayID: CGDirectDisplayID) {
        stored = headroom
        saves.append(headroom)
    }
}

/// Stands in for the delayed work `BoostEngagement` schedules, and for the
/// clock: nothing runs until the test advances time.
@MainActor
final class ManualBoostClock {
    private(set) var now: TimeInterval = 1000
    private var pending: [(id: Int, due: TimeInterval, work: @MainActor () -> Void)] = []
    private var nextID = 0

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        let id = nextID
        nextID += 1
        pending.append((id, now + delay, work))
        return { [weak self] in
            MainActor.assumeIsolated {
                self?.pending.removeAll { $0.id == id }
            }
        }
    }

    var pendingCount: Int { pending.count }

    /// Moves time forward, running whatever comes due, in order.
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = pending.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            pending.removeAll { $0.id == next.id }
            now = max(now, next.due)
            next.work()
        }
        now = target
    }
}

/// Everything a `BoostEngagement` test needs, wired together: a fake display
/// table, overlay, headroom, session and clock, and private notification
/// centers so nothing real is posted to or received from.
@MainActor
final class BoostHarness {
    static let displayID: CGDirectDisplayID = 1

    let tables: FakeGammaTables
    let overlay = FakeOverlay()
    let store = FakeHeadroomStore()
    let clock = ManualBoostClock()
    let workspaceCenter = NotificationCenter()
    let distributedCenter = NotificationCenter()
    let appCenter = NotificationCenter()
    var headroom: CGFloat = 3.2
    var session = SessionSnapshot.idle
    var displayActive = true
    private(set) var overlayMountCount = 0
    var overlayAvailable = true
    let baseline: GammaTable
    private(set) var engagement: BoostEngagement!

    init(baseline: GammaTable = FakeGammaTables.identity(), storedHeadroom: CGFloat? = nil) {
        self.baseline = baseline
        self.tables = FakeGammaTables(live: baseline)
        self.store.stored = storedHeadroom

        var environment = BoostEngagement.Environment()
        environment.tables = tables
        environment.makeOverlay = { [unowned self] _ in
            overlayMountCount += 1
            return overlayAvailable ? overlay : nil
        }
        environment.isDisplayActive = { [unowned self] _ in displayActive }
        environment.sessionSnapshot = { [unowned self] in session }
        environment.headroomStore = store
        environment.workspaceCenter = workspaceCenter
        environment.distributedCenter = distributedCenter
        environment.appCenter = appCenter
        environment.schedule = { [unowned self] delay, work in clock.schedule(delay, work) }
        environment.now = { [unowned self] in clock.now }
        engagement = BoostEngagement(
            displayID: Self.displayID,
            environment: environment,
            readHeadroom: { [unowned self] _ in (headroom, 16) }
        )
    }

    /// The baseline scaled by `factor`, as BrightBoi would write it.
    func scaled(_ factor: CGGammaValue) -> GammaTable {
        baseline.scaled(by: factor)
    }
}
