import Foundation
import CoreGraphics
import AppKit

/// Reads and writes a display's transfer table. A seam so the engagement
/// logic can be tested against a fake table instead of the real display.
@MainActor
protocol GammaTableAccessing {
    func capture(displayID: CGDirectDisplayID) -> GammaTable?
    /// `true` when the write succeeded.
    func apply(_ table: GammaTable, to displayID: CGDirectDisplayID) -> Bool
}

/// The real tables, through CoreGraphics.
struct SystemGammaTables: GammaTableAccessing {
    func capture(displayID: CGDirectDisplayID) -> GammaTable? {
        GammaTable.capture(displayID: displayID)
    }

    func apply(_ table: GammaTable, to displayID: CGDirectDisplayID) -> Bool {
        table.apply(to: displayID)
    }
}

/// The window that keeps EDR headroom available, as `BoostEngagement` uses it.
/// `EDROverlayWindow` is the real one.
@MainActor
protocol EDROverlaying: AnyObject {
    /// Whether the window is on screen and not covered, per its occlusion
    /// state.
    var isVisible: Bool { get }
    /// Called when `isVisible` may have changed.
    var onVisibilityChange: (() -> Void)? { get set }
    /// Moves the window onto `displayID` and draws a frame there. `false`
    /// when that display has no screen right now.
    func rehome(to displayID: CGDirectDisplayID) -> Bool
    /// Orders the window to the front again.
    func bringToFront()
    func engageEDR()
    func disengageEDR()
}

/// Remembers the largest unthrottled EDR headroom seen on a display, across
/// launches, so the Boost ceiling is right from the first engagement.
@MainActor
protocol ObservedHeadroomStoring {
    func load(forDisplay displayID: CGDirectDisplayID) -> CGFloat?
    func save(_ headroom: CGFloat, forDisplay displayID: CGDirectDisplayID)
}

/// Stores the observed headroom in `UserDefaults`, keyed by the display's
/// vendor, model and serial numbers so a different panel never inherits it.
struct UserDefaultsObservedHeadroomStore: ObservedHeadroomStoring {
    private static let keyPrefix = "com.ptlghost.BrightBoi.observedMaxHeadroom."
    private let defaults = UserDefaults.standard

    private func key(for displayID: CGDirectDisplayID) -> String {
        "\(Self.keyPrefix)\(CGDisplayVendorNumber(displayID))-\(CGDisplayModelNumber(displayID))-\(CGDisplaySerialNumber(displayID))"
    }

    func load(forDisplay displayID: CGDirectDisplayID) -> CGFloat? {
        let value = defaults.double(forKey: key(for: displayID))
        return value > 1 ? CGFloat(value) : nil
    }

    func save(_ headroom: CGFloat, forDisplay displayID: CGDirectDisplayID) {
        defaults.set(Double(headroom), forKey: key(for: displayID))
    }
}

/// Owns the state Extended Brightness / Boost needs across calls: the
/// built-in display's original gamma table (the baseline), the table this
/// instance last wrote, and the EDR overlay that keeps system-wide EDR
/// headroom available while boosted. Used by `LiveDisplayBrightnessProvider`.
///
/// Boost scales the baseline table by a factor between 1.0 and the panel's
/// ceiling (`BoostCalibration`). The factor actually written is clamped to
/// the EDR headroom the display grants at that moment
/// (`BoostHeadroom.effectiveFactor`): the headroom takes about a second to
/// ramp up after the overlay asks for it, and scaling past it clips
/// highlights to white instead of brightening the screen. So Boost steps up
/// as the headroom arrives, and backs off if it is throttled.
///
/// The baseline is never trusted for longer than the table it belongs to;
/// `GammaTable.baselineDecision` describes how a table changed by something
/// else is told apart from one this instance wrote.
///
/// Boost is kept alive against the things that undo it:
/// - Display sleep and wake, a display reconfiguration, a change of the
///   display's colour profile and a session switch reset or replace the
///   table. Each triggers a re-validation (`reassert`) at once and again
///   shortly afterwards, since the system may finish its own reset a moment
///   after the notification.
/// - The screen saver, the lock screen and another user's session cover the
///   overlay, and WindowServer then withdraws the headroom. These, and a
///   closed lid, suspend Boost (`BoostSuspension`): the unscaled baseline is
///   written and EDR released, and Boost resumes once none of them holds.
/// - If the overlay is covered by something no notification announced, it is
///   brought to the front once; if it is still covered, Boost is suspended
///   until it is visible again.
/// - Headroom that stays missing for no announced reason gets the overlay
///   asked again (`HeadroomStarvationMonitor`).
///
/// The overlay is created on first engagement and kept for the life of the
/// process (see `EDROverlayWindow`); disengaging restores the gamma table and
/// releases the EDR request without tearing the window down.
///
/// Reimplemented independently from a description of the technique —
/// BrightIntosh (GPLv3) was read for research only, not copied.
///
/// `@MainActor`: `EDROverlayWindow` is main-thread-only (`NSWindow`/`MTKView`),
/// and `apply(percentage:)` — the only caller of `engage`/`disengage` — is
/// only ever driven synchronously from the main thread today (the slider
/// binding, the key tap), mirroring the whole app's implicit single-threaded
/// UI-driven design.
@MainActor
final class BoostEngagement {
    /// How often the granted EDR headroom is checked for as long as Boost is
    /// engaged. The headroom can take many seconds to arrive after the
    /// overlay asks for it, and can be taken back later when the panel
    /// throttles, and `didChangeScreenParametersNotification` is not
    /// guaranteed to announce either, so the factor follows it by polling.
    /// Nothing polls while Boost is off.
    static let headroomPollInterval: TimeInterval = 0.25

    /// How long after a wake, reconfiguration or session event the display
    /// is checked again, on top of the check made at once. The system may
    /// reset the table some moments after it announces the event.
    static let reassertionDelays: [TimeInterval] = [0.5, 2.0]

    /// How long an overlay that lost visibility gets, after being brought to
    /// the front, before Boost is suspended for it.
    static let occlusionGrace: TimeInterval = 0.5

    /// How often a suspended engagement reads the session back to repair a
    /// reason that should have ended.
    static let sessionRepairInterval: TimeInterval = 2

    /// Everything outside the class that it reads or waits on, so tests can
    /// stand in for each. The defaults are the real system.
    @MainActor
    struct Environment {
        var tables: GammaTableAccessing = SystemGammaTables()
        var makeOverlay: (CGDirectDisplayID) -> EDROverlaying? = { EDROverlayWindow.mount(on: $0) }
        var isDisplayActive: (CGDirectDisplayID) -> Bool = { BuiltInDisplay.isActive($0) }
        var sessionSnapshot: () -> SessionSnapshot = { SessionSnapshot.current() }
        var headroomStore: ObservedHeadroomStoring = UserDefaultsObservedHeadroomStore()
        var workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
        var distributedCenter: NotificationCenter = DistributedNotificationCenter.default()
        var appCenter: NotificationCenter = .default
        /// Runs `work` after `delay` and returns a closure that cancels it.
        var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { delay, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        }
        /// Monotonic seconds.
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    /// `nil` while the built-in display is not online. Boost cannot engage
    /// then, and nothing here ever falls back to another display.
    private(set) var displayID: CGDirectDisplayID?

    private let environment: Environment
    private let readHeadroom: (CGDirectDisplayID) -> (current: CGFloat, potential: CGFloat)?

    /// The display's own table as it was before Boost scaled it. `nil`
    /// whenever Boost is not engaged.
    private var baselineGammaTable: GammaTable?
    /// The table this instance itself last wrote to the display — compared
    /// against the live table before anything is written or restored, so a
    /// second copy (or another app) that changed the display in the meantime
    /// doesn't get its table clobbered by a stale write.
    private var lastWrittenGammaTable: GammaTable?
    private var overlay: EDROverlaying?
    /// How far through the Boost range the user asked to be (0...1). The
    /// table factor is derived from it each time, so a ceiling learned later
    /// applies without asking again.
    private var requestedBoostFraction = 0.0
    /// The factor actually written — the delivered brightness,
    /// 100 + (effective - 1) * 100 percent on a linear table.
    private(set) var effectiveFactor: CGGammaValue = 1.0
    private(set) var suspension = BoostSuspension()
    private var starvation = HeadroomStarvationMonitor()
    private var observedHeadroom: ObservedHeadroom
    private var headroomTimer: Timer?
    private var pendingReassertions: [() -> Void] = []
    private var cancelOcclusionCheck: (() -> Void)?
    private var lastSessionRepair: TimeInterval?
    /// Set when a resume could not mount the overlay yet (the screen was not
    /// back); the headroom poll retries until it succeeds.
    private var resumePending = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    var isEngaged: Bool { baselineGammaTable != nil }

    /// The largest luminance ratio 200% maps to on this panel right now.
    var ceilingRatio: Double {
        BoostCalibration.ceilingRatio(observedHeadroom: observedHeadroom.maximum)
    }

    init(
        displayID: CGDirectDisplayID?,
        environment: Environment = Environment(),
        readHeadroom: @escaping (CGDirectDisplayID) -> (current: CGFloat, potential: CGFloat)? = { BoostHeadroom.read(displayID: $0) }
    ) {
        self.displayID = displayID
        self.environment = environment
        self.readHeadroom = readHeadroom
        self.observedHeadroom = ObservedHeadroom(maximum: displayID.flatMap { environment.headroomStore.load(forDisplay: $0) })

        for entry in BoostNotifications.all {
            let center = entry.source == .workspace ? environment.workspaceCenter : environment.distributedCenter
            let event = entry.event
            let token = center.addObserver(forName: entry.name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
            }
            observers.append((center, token))
        }
        // A normal quit leaves through `BrightnessController`'s termination
        // hook too; this is the safety net for any other route to
        // termination. A crash or SIGKILL can't run it, and there
        // WindowServer discards the dead client's table.
        let terminationToken = environment.appCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.disengage()
            }
        }
        observers.append((environment.appCenter, terminationToken))
    }

    isolated deinit {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        headroomTimer?.invalidate()
        cancelScheduledWork()
    }

    /// Engages Boost at `boostFraction` (0...1 of the Boost range). Always
    /// works from a freshly validated view of the display: captures its live
    /// table, refuses if it already looks scaled by another process (adopting
    /// its table as the baseline would compound the scaling on top of
    /// theirs), and refuses if the capture itself fails. Only once the
    /// baseline is settled and the overlay is mounted on the built-in screen
    /// does EDR get requested and the table get scaled, so a failure at any
    /// step leaves the display exactly as it was found.
    ///
    /// While Boost is suspended (screen saver, lock screen, ...) the request
    /// is remembered and the display keeps its unscaled table; Boost appears
    /// when the suspension ends.
    @discardableResult
    func engage(boostFraction: Double) -> BrightnessApplyOutcome {
        guard let displayID else { return .displayUnavailable }
        // The session is read back only when this could change what Boost
        // does; while Boost runs undisturbed the notifications are enough,
        // and a slider drag must not scan the process list on every tick.
        if !isEngaged || suspension.isSuspended { reconcileSession() }
        guard let live = environment.tables.capture(displayID: displayID) else { return .captureFailed }

        switch GammaTable.baselineDecision(live: live, lastWritten: lastWrittenGammaTable) {
        case .keep:
            break
        case .adopt:
            baselineGammaTable = live
            lastWrittenGammaTable = nil
        case .foreignBooster:
            // If this instance was boosting, whoever changed the table has
            // taken over; step aside without writing anything back.
            if isEngaged { disengage() }
            return .boostBlockedByOtherApp
        }

        requestedBoostFraction = min(max(boostFraction.isFinite ? boostFraction : 0, 0), 1)

        if suspension.isSuspended {
            // Nothing to show until the suspension ends: hold the baseline
            // as it is, without mounting the overlay on a covered screen.
            if lastWrittenGammaTable == nil { lastWrittenGammaTable = baselineGammaTable }
            effectiveFactor = 1.0
            return .applied
        }

        guard mountOrRehomeOverlay(on: displayID) else {
            // Nothing was scaled: forget a baseline adopted a moment ago.
            if lastWrittenGammaTable == nil { baselineGammaTable = nil }
            return .displayUnavailable
        }

        overlay?.engageEDR()
        starvation.reset()
        guard writeCurrentFactor(force: true) else {
            disengage()
            return .captureFailed
        }
        startHeadroomTracking()
        return .applied
    }

    /// Restores the display's table and releases the EDR request. Always
    /// releases EDR, even when no table was captured — a failed engagement
    /// must not leave the display stuck in EDR mode.
    func disengage() {
        stopHeadroomTracking()
        cancelScheduledWork()
        starvation.reset()
        // A covered overlay is only meaningful while Boost runs; left set,
        // it would hold every later engagement back.
        suspension.set(.overlayOccluded, active: false)
        resumePending = false
        requestedBoostFraction = 0
        effectiveFactor = 1.0
        defer {
            baselineGammaTable = nil
            lastWrittenGammaTable = nil
        }
        guard let baselineGammaTable, let displayID else {
            overlay?.disengageEDR()
            return
        }
        // Restoring the specific captured table for `displayID` is already
        // scoped to the built-in display — Boost must never touch an
        // external monitor. (`CGDisplayRestoreColorSyncSettings()` resets
        // ColorSync for *every* connected display, so it is not used.)
        //
        // Only restore if the table we last wrote is still the one live on
        // the display — if it isn't, another process took over the display
        // while this one was boosted, and writing our old baseline back
        // would stomp on whatever that process left there.
        if liveTableIsUntouched(on: displayID) {
            _ = environment.tables.apply(baselineGammaTable, to: displayID)
        }
        overlay?.disengageEDR()
    }

    /// Whether the display still holds the table this instance last wrote.
    /// `true` when there is nothing to compare or the display cannot be read,
    /// so a failed read never stops a restore.
    private func liveTableIsUntouched(on displayID: CGDirectDisplayID) -> Bool {
        guard let lastWrittenGammaTable, let live = environment.tables.capture(displayID: displayID) else { return true }
        return live.matches(lastWrittenGammaTable)
    }

    /// Follows the built-in display when the display configuration changes:
    /// a different id (or none, when the lid closed) releases Boost on the
    /// old display first; the same id re-homes the overlay and re-checks the
    /// granted headroom against what was written. A built-in display that is
    /// online but no longer active (lid closed) suspends Boost until it is
    /// active again.
    func displayConfigurationChanged(displayID newID: CGDirectDisplayID?) {
        if newID != displayID {
            disengage()
            suspension.set(.displayInactive, active: false)
            displayID = newID
            observedHeadroom = ObservedHeadroom(maximum: newID.flatMap { environment.headroomStore.load(forDisplay: $0) })
            return
        }
        guard let newID else { return }
        // Tracked even while Boost is off, so a later engagement does not
        // start out with a stale reason.
        setSuspended(.displayInactive, active: !environment.isDisplayActive(newID))
        reassertNowAndSoonAfter()
    }

    /// Reacts to a system event. Internal rather than private so tests can
    /// drive it without posting notifications; the real wiring is
    /// `BoostNotifications.all`.
    func handle(_ event: BoostSystemEvent) {
        switch event {
        case .screenSaverStarted:
            setSuspended(.screenSaver, active: true)
        case .screenSaverStopped:
            setSuspended(.screenSaver, active: false)
            reassertNowAndSoonAfter()
        case .screenLocked:
            setSuspended(.screenLocked, active: true)
        case .screenUnlocked:
            setSuspended(.screenLocked, active: false)
            reassertNowAndSoonAfter()
        case .sessionResignedActive:
            setSuspended(.sessionInactive, active: true)
        case .sessionBecameActive:
            setSuspended(.sessionInactive, active: false)
            reassertNowAndSoonAfter()
        case .systemWake, .displaysWake, .displayProfileChanged:
            reassertNowAndSoonAfter()
        case .spaceChanged:
            guard isEngaged, !suspension.isSuspended, let displayID else { return }
            _ = overlay?.rehome(to: displayID)
        }
    }

    // MARK: - Suspension

    /// Adds or removes a suspension reason and, when that flips whether
    /// Boost is suspended, puts the display into the matching state.
    private func setSuspended(_ reason: BoostSuspendReason, active: Bool) {
        let changed = suspension.set(reason, active: active)
        guard changed, isEngaged else { return }
        if suspension.isSuspended {
            // The timer keeps running: while suspended it repairs reasons
            // that a missed notification left set.
            starvation.reset()
            cancelOcclusionCheck?()
            cancelOcclusionCheck = nil
            // The unscaled baseline goes back only if the display still
            // holds the table written here; another process's table stays.
            if let displayID, liveTableIsUntouched(on: displayID) {
                writeCurrentFactor(force: true)
            }
            overlay?.disengageEDR()
        } else {
            resumeFromSuspension()
        }
    }

    /// Puts Boost back after the last suspension reason ended: the overlay
    /// asks for EDR again, and the table is validated before it is scaled,
    /// since it may have been replaced in the meantime.
    private func resumeFromSuspension() {
        guard let displayID, environment.isDisplayActive(displayID) else { return }
        guard mountOrRehomeOverlay(on: displayID) else {
            // The screen may not be back yet; the poll retries.
            resumePending = true
            startHeadroomTracking()
            return
        }
        resumePending = false
        overlay?.engageEDR()
        starvation.reset()
        revalidateTable(forceWrite: true)
        startHeadroomTracking()
    }

    /// The system announces lock, unlock, screen saver and session changes by
    /// notification, and a missed one would leave Boost suspended for good, so
    /// the reasons that mirror the session are read back from the system.
    private func reconcileSession() {
        let snapshot = environment.sessionSnapshot()
        setSuspended(.screenLocked, active: snapshot.isScreenLocked)
        setSuspended(.sessionInactive, active: !snapshot.isOnConsole)
        setSuspended(.screenSaver, active: snapshot.isScreenSaverRunning)
        if let displayID {
            setSuspended(.displayInactive, active: !environment.isDisplayActive(displayID))
        }
    }

    // MARK: - Re-validation

    /// While engaged: re-homes the overlay, and re-validates the display's
    /// table against what was last written. An unchanged table just gets its
    /// factor re-clamped to the current headroom; a changed one that still
    /// looks like a plain table becomes the new baseline and is re-scaled; a
    /// changed one that does not is left alone.
    func reassert() {
        guard isEngaged, let displayID else { return }
        reconcileSession()
        guard environment.isDisplayActive(displayID) else { return }
        if !suspension.isSuspended {
            guard mountOrRehomeOverlay(on: displayID) else { return }
        }
        revalidateTable(forceWrite: false)
        if !suspension.isSuspended {
            startHeadroomTracking()
        }
    }

    /// Compares the live table with what was last written and acts on the
    /// verdict (`GammaTable.baselineDecision`): keep the baseline and rewrite
    /// the factor, adopt the live table as the new baseline, or leave a
    /// foreign table alone.
    private func revalidateTable(forceWrite: Bool) {
        guard let displayID, let live = environment.tables.capture(displayID: displayID) else { return }
        switch GammaTable.baselineDecision(live: live, lastWritten: lastWrittenGammaTable) {
        case .keep:
            writeCurrentFactor(force: forceWrite)
        case .adopt:
            baselineGammaTable = live
            lastWrittenGammaTable = nil
            writeCurrentFactor(force: true)
        case .foreignBooster:
            break
        }
    }

    /// Re-validates right away and again after each of
    /// `reassertionDelays`, replacing any checks still pending from an
    /// earlier event. Each pass goes through the same comparison; nothing is
    /// re-captured unconditionally, since a table the system did *not* reset
    /// would otherwise be adopted as a baseline while still scaled.
    private func reassertNowAndSoonAfter() {
        guard isEngaged else { return }
        reassert()
        cancelScheduledReassertions()
        pendingReassertions = Self.reassertionDelays.map { delay in
            environment.schedule(delay) { [weak self] in
                self?.reassert()
            }
        }
    }

    private func cancelScheduledReassertions() {
        pendingReassertions.forEach { $0() }
        pendingReassertions = []
    }

    private func cancelScheduledWork() {
        cancelScheduledReassertions()
        cancelOcclusionCheck?()
        cancelOcclusionCheck = nil
    }

    // MARK: - Overlay

    /// Mounts the overlay on the built-in screen, or moves an existing one
    /// there. `false` when that screen isn't available right now. A failed
    /// mount leaves no overlay behind, so the next call simply retries.
    private func mountOrRehomeOverlay(on displayID: CGDirectDisplayID) -> Bool {
        if let overlay {
            return overlay.rehome(to: displayID)
        }
        guard let mounted = environment.makeOverlay(displayID) else {
            Log.display.error("Could not mount the EDR overlay on display \(displayID, privacy: .public)")
            return false
        }
        mounted.onVisibilityChange = { [weak self] in
            self?.overlayVisibilityChanged()
        }
        overlay = mounted
        return true
    }

    /// The fallback for an overlay covered by something no notification
    /// announced (a full-screen app that captured the display, another
    /// screen-saver-level window). The explicit signals above are the primary
    /// mechanism, because the occlusion state can lag and can report visible
    /// after a Space switch while still covered. Once, the overlay is brought
    /// to the front; if it is still covered after a short grace, Boost is
    /// suspended until it is visible again. Nothing is brought to the front
    /// while another reason holds, which would fight the screen saver and keep
    /// the panel in EDR behind it.
    func overlayVisibilityChanged() {
        guard let overlay else { return }
        if overlay.isVisible {
            cancelOcclusionCheck?()
            cancelOcclusionCheck = nil
            setSuspended(.overlayOccluded, active: false)
            return
        }
        guard isEngaged, !suspension.isSuspended else { return }
        overlay.bringToFront()
        cancelOcclusionCheck?()
        cancelOcclusionCheck = environment.schedule(Self.occlusionGrace) { [weak self] in
            guard let self, self.isEngaged, !self.suspension.isSuspended, self.overlay?.isVisible == false else { return }
            self.setSuspended(.overlayOccluded, active: true)
        }
    }

    // MARK: - Factor

    /// The factor Boost asks for now, before the clamp to the headroom.
    private var requestedFactor: CGFloat {
        BoostCalibration.tableFactor(forBoostFraction: requestedBoostFraction, observedHeadroom: observedHeadroom.maximum)
    }

    /// Writes what `BoostSuspension.plan` calls for: the baseline scaled by
    /// the requested factor clamped to the headroom granted right now, or the
    /// unscaled baseline while suspended. Returns `false` only when the write
    /// itself failed. Skips the write when it would change nothing, unless
    /// `force`.
    @discardableResult
    private func writeCurrentFactor(force: Bool, headroom knownHeadroom: CGFloat? = nil) -> Bool {
        guard let displayID, let baselineGammaTable else { return true }
        // A display that is not active has nothing to write to.
        guard environment.isDisplayActive(displayID) else { return true }
        let headroom = knownHeadroom ?? readHeadroom(displayID)?.current ?? 1.0
        let plan = suspension.plan(requestedFactor: requestedFactor, headroom: headroom)
        let effective = CGGammaValue(plan.factor)
        guard force || lastWrittenGammaTable == nil || BoostHeadroom.shouldRewrite(from: CGFloat(effectiveFactor), to: CGFloat(effective)) else {
            return true
        }
        let scaled = baselineGammaTable.scaled(by: effective)
        guard environment.tables.apply(scaled, to: displayID) else { return false }
        lastWrittenGammaTable = scaled
        effectiveFactor = effective
        return true
    }

    /// Follows the granted headroom for as long as Boost is engaged, so the
    /// factor steps up as headroom arrives and backs off if it is throttled.
    private func startHeadroomTracking() {
        guard headroomTimer == nil else { return }
        headroomTimer = Timer.scheduledTimer(withTimeInterval: Self.headroomPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollHeadroom()
            }
        }
    }

    /// One step of headroom tracking, run by the timer; internal so tests can
    /// run it directly. Learns the panel's unthrottled headroom, asks the
    /// overlay for EDR again if the headroom has been missing for a while,
    /// and re-clamps the factor.
    func pollHeadroom() {
        guard isEngaged, let displayID else {
            stopHeadroomTracking()
            return
        }
        let now = environment.now()
        guard !suspension.isSuspended else {
            repairSuspension(now: now)
            return
        }
        if resumePending {
            resumeFromSuspension()
            return
        }
        let headroom = readHeadroom(displayID)?.current ?? 1.0

        if observedHeadroom.record(headroom: headroom, now: now), let maximum = observedHeadroom.maximum {
            environment.headroomStore.save(maximum, forDisplay: displayID)
        }
        if starvation.shouldRequestAgain(now: now, headroom: headroom, wantsBoost: requestedFactor > 1) {
            Log.display.notice("EDR headroom missing while boosted; asking the overlay again")
            _ = overlay?.rehome(to: displayID)
            overlay?.engageEDR()
        }
        writeCurrentFactor(force: false, headroom: headroom)
    }

    /// While suspended, reads the session back every `sessionRepairInterval`
    /// so a reason that outlived its own "stopped" notification (a screen
    /// saver process still listed right after it ended) or a missed
    /// notification cannot leave Boost off for good.
    private func repairSuspension(now: TimeInterval) {
        if let lastSessionRepair, now - lastSessionRepair < Self.sessionRepairInterval { return }
        lastSessionRepair = now
        if suspension.contains(.overlayOccluded), overlay?.isVisible != false {
            setSuspended(.overlayOccluded, active: false)
        }
        reconcileSession()
    }

    private func stopHeadroomTracking() {
        headroomTimer?.invalidate()
        headroomTimer = nil
    }
}

/// Wraps `CGGetDisplayTransferByTable`/`CGSetDisplayTransferByTable` (public,
/// documented CoreGraphics APIs) at the display's own table resolution. Not
/// `private` so `GammaTableTests`-style unit tests can exercise
/// `looksAlreadyBoosted`, `matches` and `baselineDecision` directly via
/// `@testable import`.
struct GammaTable: Equatable {
    /// Used when the display doesn't report its table capacity.
    static let fallbackSampleCount: UInt32 = 256

    /// The live built-in panel's table peaks at `0.99999994`, comfortably
    /// under 1.0. Covers tables that report their samples unclamped: a peak
    /// that clears this by more than float noise has already been scaled by
    /// something else. Read-back tables are clamped at 1.0, so those are
    /// caught by the plateau check below instead.
    private static let alreadyBoostedThreshold: CGGammaValue = 1.0 + 1e-3

    /// `CGGetDisplayTransferByTable` never reports a sample above 1.0: a table
    /// scaled past identity reads back clamped, so its peak alone can't give
    /// the scaling away. It shows as a plateau instead — every sample beyond
    /// `1/factor` of the range reads exactly 1.0. A plain table has only its
    /// last few samples at the top; more than this fraction of the samples
    /// there means something scaled it (a factor of about 1.03 or more).
    private static let saturationThreshold: CGGammaValue = 1.0 - 1e-3
    private static let saturatedFractionLimit = 0.03

    /// Read-back can be quantized to the hardware LUT, so an exact
    /// floating-point match is too strict for "is this still our table".
    /// Wide enough to absorb resampling between table sizes.
    private static let matchTolerance: CGGammaValue = 3e-3

    /// A real table never decreases; a sample dipping by more than float
    /// noise means this isn't a plain calibration curve.
    private static let monotonicTolerance: CGGammaValue = 1e-4

    var red: [CGGammaValue]
    var green: [CGGammaValue]
    var blue: [CGGammaValue]

    /// What to do with the display's live table before writing Boost to it.
    enum BaselineDecision: Equatable {
        /// The live table is the one this instance wrote: keep the baseline.
        case keep
        /// Something else changed the table and it looks like a plain,
        /// unboosted table: take it as the new baseline.
        case adopt
        /// The live table isn't ours and doesn't look like a plain table —
        /// another process is boosting or otherwise reshaping the display.
        case foreignBooster
    }

    /// Decides whether to keep the current baseline, adopt the live table as
    /// a new one, or step aside. `lastWritten` is `nil` when Boost isn't
    /// engaged (there's no baseline yet), in which case the live table is
    /// simply judged on its own.
    static func baselineDecision(live: GammaTable, lastWritten: GammaTable?) -> BaselineDecision {
        if let lastWritten, live.matches(lastWritten) { return .keep }
        return live.isPlainBaseline ? .adopt : .foreignBooster
    }

    /// Captures at the display's own table capacity (1024 samples on the
    /// built-in panel), so a restore is bit-for-bit the calibration the
    /// display started with rather than a resampled copy of it.
    static func capture(displayID: CGDirectDisplayID) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        let requested = capacity > 0 ? capacity : fallbackSampleCount
        var red = [CGGammaValue](repeating: 0, count: Int(requested))
        var green = [CGGammaValue](repeating: 0, count: Int(requested))
        var blue = [CGGammaValue](repeating: 0, count: Int(requested))
        var actualSampleCount: UInt32 = 0
        let result = CGGetDisplayTransferByTable(displayID, requested, &red, &green, &blue, &actualSampleCount)
        guard result == .success else {
            Log.display.error("CGGetDisplayTransferByTable failed with code \(result.rawValue, privacy: .public)")
            return nil
        }
        guard let table = trimmed(red: red, green: green, blue: blue, validSampleCount: Int(min(actualSampleCount, requested))) else {
            Log.display.error("CGGetDisplayTransferByTable returned no samples")
            return nil
        }
        return table
    }

    /// Keeps only the samples the system actually filled in — a shorter
    /// table than requested would otherwise leave a zero-filled tail that
    /// maps the top of the range to black. `nil` when no sample is valid.
    static func trimmed(red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue], validSampleCount: Int) -> GammaTable? {
        let count = min(validSampleCount, red.count, green.count, blue.count)
        guard count > 0 else { return nil }
        return GammaTable(red: Array(red.prefix(count)), green: Array(green.prefix(count)), blue: Array(blue.prefix(count)))
    }

    /// `true` when this table has a peak above identity, or a plateau at the
    /// top of the range — the signs that something had already scaled it up,
    /// per `isAlreadyBoosted(red:green:blue:)`.
    var looksAlreadyBoosted: Bool {
        Self.isAlreadyBoosted(red: red, green: green, blue: blue)
    }

    /// Extracted as a pure function over raw samples (rather than reading
    /// `self`) so tests can exercise it against an identity ramp, a ×2 ramp,
    /// a clamped read-back of one, and a real vcgt-like ramp without
    /// constructing a `GammaTable` through `capture`. Two signals: a peak
    /// above identity (an unclamped table), or a plateau at the top of the
    /// range (how a scaled table reads back, since the system clamps at 1.0).
    static func isAlreadyBoosted(red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]) -> Bool {
        [red, green, blue].contains { channel in
            guard let peak = channel.max() else { return false }
            if peak > alreadyBoostedThreshold { return true }
            let saturated = channel.filter { $0 >= saturationThreshold }.count
            return Double(saturated) / Double(channel.count) > saturatedFractionLimit
        }
    }

    /// An unboosted, well-formed table: nothing above identity, and no
    /// channel that decreases. What may safely become a Boost baseline.
    var isPlainBaseline: Bool {
        guard !looksAlreadyBoosted else { return false }
        return [red, green, blue].allSatisfy { channel in
            zip(channel, channel.dropFirst()).allSatisfy { $1 >= $0 - Self.monotonicTolerance }
        }
    }

    /// Per-sample comparison within `matchTolerance`, rather than exact
    /// equality — used to check the live table is still the one this
    /// instance wrote, not another process's table from taking over the
    /// display in the meantime. Samples above 1.0 compare as 1.0, because
    /// that is all a read-back of the live table ever reports: a boosted
    /// table this instance wrote must still match itself.
    func matches(_ other: GammaTable) -> Bool {
        guard red.count == other.red.count, green.count == other.green.count, blue.count == other.blue.count else { return false }
        func close(_ a: [CGGammaValue], _ b: [CGGammaValue]) -> Bool {
            zip(a, b).allSatisfy { abs(min($0, 1) - min($1, 1)) <= Self.matchTolerance }
        }
        return close(red, other.red) && close(green, other.green) && close(blue, other.blue)
    }

    func scaled(by factor: CGGammaValue) -> GammaTable {
        GammaTable(
            red: red.map { $0 * factor },
            green: green.map { $0 * factor },
            blue: blue.map { $0 * factor }
        )
    }

    /// Writes this table to the display, at its own sample count. A failure
    /// here (e.g. mid-restore) would silently leave the display stuck
    /// over-brightened, so it's worth surfacing even though there's no UI to
    /// show it in — matches the dlopen/dlsym failure logging in
    /// `LiveDisplayBrightnessProvider`. Returns whether the write succeeded.
    @discardableResult
    func apply(to displayID: CGDirectDisplayID) -> Bool {
        // `CGSetDisplayTransferByTable` takes `const CGGammaValue *`, so the
        // arrays can be passed directly — no need to copy them into `var`s
        // first just to take their address.
        let result = CGSetDisplayTransferByTable(displayID, UInt32(red.count), red, green, blue)
        if result != .success {
            Log.display.error("CGSetDisplayTransferByTable failed with code \(result.rawValue, privacy: .public)")
        }
        return result == .success
    }
}
