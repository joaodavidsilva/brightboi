import Foundation
import CoreGraphics
import AppKit

/// Owns the state Extended Brightness / Boost needs across calls: the
/// built-in display's original gamma table (the baseline), the table this
/// instance last wrote, and the EDR overlay that keeps system-wide EDR
/// headroom available while boosted. Used by `LiveDisplayBrightnessProvider`.
///
/// Boost scales the baseline table by a factor between 1.0 and 2.0. The
/// factor actually written is clamped to the EDR headroom the display grants
/// at that moment (`BoostHeadroom.effectiveFactor`): the headroom takes about
/// a second to ramp up after the overlay asks for it, and scaling past it
/// clips highlights to white instead of brightening the screen. So Boost
/// steps up as the headroom arrives, and backs off if it is throttled.
///
/// The baseline is never trusted for longer than the table it belongs to;
/// `GammaTable.baselineDecision` describes how a table changed by something
/// else is told apart from one this instance wrote.
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

    /// How long after waking the display is checked a second time. The system
    /// may reset the table some moments after the wake notification.
    static let postWakeRecheckDelay: TimeInterval = 2.0

    /// `nil` while the built-in display is not online. Boost cannot engage
    /// then, and nothing here ever falls back to another display.
    private(set) var displayID: CGDirectDisplayID?

    private let readHeadroom: (CGDirectDisplayID) -> (current: CGFloat, potential: CGFloat)?

    /// The display's own table as it was before Boost scaled it. `nil`
    /// whenever Boost is not engaged.
    private var baselineGammaTable: GammaTable?
    /// The table this instance itself last wrote to the display — compared
    /// against the live table before anything is written or restored, so a
    /// second copy (or another app) that changed the display in the meantime
    /// doesn't get its table clobbered by a stale write.
    private var lastWrittenGammaTable: GammaTable?
    private var overlay: EDROverlayWindow?
    /// The factor asked for, and the (possibly lower) one actually written —
    /// the delivered brightness, 100 + (effective - 1) * 100 percent.
    private var requestedFactor: CGGammaValue = 1.0
    private(set) var effectiveFactor: CGGammaValue = 1.0
    private var headroomTimer: Timer?
    private var recheckWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    var isEngaged: Bool { baselineGammaTable != nil }

    init(
        displayID: CGDirectDisplayID?,
        readHeadroom: @escaping (CGDirectDisplayID) -> (current: CGFloat, potential: CGFloat)? = { BoostHeadroom.read(displayID: $0) }
    ) {
        self.displayID = displayID
        self.readHeadroom = readHeadroom
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWake()
            }
        })
        // A normal quit leaves through `BrightnessController`'s termination
        // hook too; this is the safety net for any other route to
        // termination. A crash or SIGKILL can't run it, and there
        // WindowServer discards the dead client's table.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.disengage()
            }
        })
    }

    isolated deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        headroomTimer?.invalidate()
        recheckWork?.cancel()
    }

    /// Engages Boost at `factor` (1.0...2.0). Always works from a freshly
    /// validated view of the display: captures its live table, refuses if it
    /// already looks scaled by another process (adopting its table as the
    /// baseline would compound the scaling on top of theirs), and refuses
    /// if the capture itself fails. Only once the baseline is settled and the
    /// overlay is mounted on the built-in screen does EDR get requested and
    /// the table get scaled, so a failure at any step leaves the display
    /// exactly as it was found.
    @discardableResult
    func engage(factor: CGGammaValue) -> BrightnessApplyOutcome {
        guard let displayID else { return .displayUnavailable }
        guard let live = GammaTable.capture(displayID: displayID) else { return .captureFailed }

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

        guard mountOrRehomeOverlay(on: displayID) else {
            // Nothing was scaled: forget a baseline adopted a moment ago.
            if lastWrittenGammaTable == nil { baselineGammaTable = nil }
            return .displayUnavailable
        }

        requestedFactor = factor
        overlay?.engageEDR()
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
        recheckWork?.cancel()
        requestedFactor = 1.0
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
        let untouched: Bool
        if let lastWrittenGammaTable, let live = GammaTable.capture(displayID: displayID) {
            untouched = live.matches(lastWrittenGammaTable)
        } else {
            untouched = true
        }
        if untouched {
            baselineGammaTable.apply(to: displayID)
        }
        overlay?.disengageEDR()
    }

    /// Follows the built-in display when the display configuration changes:
    /// a different id (or none, when the lid closed) releases Boost on the
    /// old display first; the same id re-homes the overlay and re-checks the
    /// granted headroom against what was written.
    func displayConfigurationChanged(displayID newID: CGDirectDisplayID?) {
        if newID != displayID {
            disengage()
            displayID = newID
        } else if isEngaged {
            reassert()
        }
    }

    /// While engaged: re-homes the overlay, and re-validates the display's
    /// table against what was last written. An unchanged table just gets its
    /// factor re-clamped to the current headroom; a changed one that still
    /// looks like a plain table becomes the new baseline and is re-scaled.
    private func reassert() {
        guard isEngaged, let displayID else { return }
        guard mountOrRehomeOverlay(on: displayID) else { return }
        guard let live = GammaTable.capture(displayID: displayID) else { return }
        switch GammaTable.baselineDecision(live: live, lastWritten: lastWrittenGammaTable) {
        case .keep:
            writeCurrentFactor(force: false)
        case .adopt:
            baselineGammaTable = live
            lastWrittenGammaTable = nil
            writeCurrentFactor(force: true)
        case .foreignBooster:
            break
        }
        startHeadroomTracking()
    }

    /// The system resets the display's table across sleep and wake, and may
    /// do so a moment after the notification, so the table is re-validated
    /// right away and once more shortly afterwards. Each pass goes through
    /// the same comparison; nothing is re-captured unconditionally, since a
    /// table the system did *not* reset would otherwise be adopted as a
    /// baseline while still scaled.
    private func handleWake() {
        guard isEngaged else { return }
        reassert()
        recheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reassert()
            }
        }
        recheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.postWakeRecheckDelay, execute: work)
    }

    /// Mounts the overlay on the built-in screen, or moves an existing one
    /// there. `false` when that screen isn't available right now. A failed
    /// mount leaves no overlay behind, so the next call simply retries.
    private func mountOrRehomeOverlay(on displayID: CGDirectDisplayID) -> Bool {
        if let overlay {
            return overlay.rehome(to: displayID)
        }
        guard let mounted = EDROverlayWindow.mount(on: displayID) else {
            FileHandle.standardError.write(Data("BrightBoi: could not mount the EDR overlay on display \(displayID)\n".utf8))
            return false
        }
        overlay = mounted
        return true
    }

    /// Writes the baseline scaled by the requested factor, clamped to the
    /// headroom granted right now. Returns `false` only when the write itself
    /// failed. Skips the write when it would change nothing, unless `force`.
    @discardableResult
    private func writeCurrentFactor(force: Bool) -> Bool {
        guard let displayID, let baselineGammaTable else { return true }
        let headroom = readHeadroom(displayID)?.current ?? 1.0
        let effective = CGGammaValue(BoostHeadroom.effectiveFactor(requested: CGFloat(requestedFactor), headroom: headroom))
        guard force || lastWrittenGammaTable == nil || BoostHeadroom.shouldRewrite(from: CGFloat(effectiveFactor), to: CGFloat(effective)) else {
            return true
        }
        let scaled = baselineGammaTable.scaled(by: effective)
        guard scaled.apply(to: displayID) else { return false }
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
                self?.headroomTick()
            }
        }
    }

    private func headroomTick() {
        guard isEngaged else {
            stopHeadroomTracking()
            return
        }
        writeCurrentFactor(force: false)
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
            FileHandle.standardError.write(Data("BrightBoi: CGGetDisplayTransferByTable failed (\(result.rawValue))\n".utf8))
            return nil
        }
        guard let table = trimmed(red: red, green: green, blue: blue, validSampleCount: Int(min(actualSampleCount, requested))) else {
            FileHandle.standardError.write(Data("BrightBoi: CGGetDisplayTransferByTable returned no samples\n".utf8))
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
            FileHandle.standardError.write(Data("BrightBoi: CGSetDisplayTransferByTable failed (\(result.rawValue))\n".utf8))
        }
        return result == .success
    }
}
