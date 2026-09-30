import AppKit
import CoreGraphics
import Foundation

/// Why Boost is held back for a while without being turned off. Boost works
/// only while the small EDR overlay window is composited on the built-in
/// display, and WindowServer takes the EDR headroom back about 15 seconds
/// after something opaque covers that pixel. Each case is a situation that
/// covers it, or that makes writing to the display pointless.
enum BoostSuspendReason: Hashable, CaseIterable {
    /// The screen saver is running.
    case screenSaver
    /// The lock screen is up.
    case screenLocked
    /// Another user's session is in front (fast user switching).
    case sessionInactive
    /// The built-in display is online but not active (lid closed).
    case displayInactive
    /// Something other than the states above keeps the overlay covered, for
    /// example a full-screen app that captured the display.
    case overlayOccluded
}

/// The set of active `BoostSuspendReason`s, and what to put on the display
/// given them. Boost resumes only when the set is empty: separate "stopped"
/// handlers would otherwise resume while another reason still holds, for
/// instance when the screen saver ends while the lock screen is still up.
struct BoostSuspension: Equatable {
    private(set) var reasons: Set<BoostSuspendReason> = []

    var isSuspended: Bool { !reasons.isEmpty }

    /// What the display should get right now.
    struct Plan: Equatable {
        /// The gamma factor to write: 1.0 (the unscaled baseline) while
        /// suspended, otherwise the requested factor clamped to the headroom.
        var factor: CGFloat
        /// Whether the overlay should be asking for EDR.
        var wantsEDR: Bool
    }

    /// Adds or removes `reason`. `true` when that changed whether Boost is
    /// suspended at all, which is when the display needs touching.
    @discardableResult
    mutating func set(_ reason: BoostSuspendReason, active: Bool) -> Bool {
        let was = isSuspended
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        return was != isSuspended
    }

    func contains(_ reason: BoostSuspendReason) -> Bool {
        reasons.contains(reason)
    }

    /// While suspended the unscaled baseline is written and EDR is released,
    /// whatever the requested factor; a change of the requested factor is
    /// remembered by the caller and takes effect on resume. Otherwise the
    /// factor follows the granted headroom (`BoostHeadroom.effectiveFactor`),
    /// so Boost comes back as the headroom returns instead of jumping ahead
    /// of it and clipping.
    func plan(requestedFactor: CGFloat, headroom: CGFloat) -> Plan {
        guard !isSuspended else { return Plan(factor: 1, wantsEDR: false) }
        return Plan(factor: BoostHeadroom.effectiveFactor(requested: requestedFactor, headroom: headroom), wantsEDR: true)
    }

    /// Brings the three reasons that mirror the session into line with
    /// `snapshot`. The system announces lock, unlock, screen saver and session
    /// changes by notification, and a missed one would leave Boost suspended
    /// for good; reading the state back repairs that.
    mutating func reconcile(with snapshot: SessionSnapshot) {
        set(.screenLocked, active: snapshot.isScreenLocked)
        set(.sessionInactive, active: !snapshot.isOnConsole)
        set(.screenSaver, active: snapshot.isScreenSaverRunning)
    }
}

/// What the system says about the login session right now.
struct SessionSnapshot: Equatable {
    var isScreenLocked = false
    var isOnConsole = true
    var isScreenSaverRunning = false

    static let idle = SessionSnapshot()

    /// Reads the live session: the lock flag and console ownership from
    /// CoreGraphics, and the screen saver from its engine process.
    @MainActor
    static func current() -> SessionSnapshot {
        let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (dictionary?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        let onConsole = (dictionary?["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue ?? true
        let screenSaver = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine"
        }
        return SessionSnapshot(isScreenLocked: locked, isOnConsole: onConsole, isScreenSaverRunning: screenSaver)
    }
}

/// A system event Boost reacts to, separated from the notification that
/// announces it so the reaction can be tested without posting any.
enum BoostSystemEvent: Equatable {
    case systemWake
    case displaysWake
    case sessionResignedActive
    case sessionBecameActive
    case screenSaverStarted
    case screenSaverStopped
    case screenLocked
    case screenUnlocked
    case displayProfileChanged
    case spaceChanged
}

/// Which notification center each `BoostSystemEvent` arrives on, and under
/// what name.
enum BoostNotifications {
    enum Source { case workspace, distributed }

    /// `com.apple.screensaver.*` and `com.apple.screenIsLocked/Unlocked` are
    /// the distributed notifications `loginwindow` and the screen saver post
    /// (both names appear in macOS 27's loginwindow). The two ColorSync names
    /// are the exported constants `kColorSyncDeviceProfilesNotification` and
    /// `kColorSyncDisplayDeviceProfilesNotification`, sent when a display's
    /// profile, and with it its calibration table, changes.
    static let all: [(source: Source, name: Notification.Name, event: BoostSystemEvent)] = [
        (.workspace, NSWorkspace.didWakeNotification, .systemWake),
        (.workspace, NSWorkspace.screensDidWakeNotification, .displaysWake),
        (.workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive),
        (.workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
        (.workspace, NSWorkspace.activeSpaceDidChangeNotification, .spaceChanged),
        (.distributed, Notification.Name("com.apple.screensaver.didstart"), .screenSaverStarted),
        (.distributed, Notification.Name("com.apple.screensaver.didstop"), .screenSaverStopped),
        (.distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked),
        (.distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked),
        (.distributed, Notification.Name("com.apple.ColorSync.DeviceProfilesNotification"), .displayProfileChanged),
        (.distributed, Notification.Name("com.apple.ColorSync.DisplayProfileNotification"), .displayProfileChanged)
    ]
}

/// Spots EDR headroom that is missing although Boost wants it, for a reason
/// none of the events above announced, so the overlay can be asked again.
/// Pure: the caller passes in the time.
struct HeadroomStarvationMonitor {
    /// Headroom below this counts as none at all: EDR is off, or the overlay
    /// is not being composited.
    static let starvedHeadroom: CGFloat = 1.05
    /// How long the headroom has to stay missing before the overlay is asked
    /// again. The headroom takes about a second to ramp up after a request.
    static let patience: TimeInterval = 2.5
    /// The shortest gap between two requests, so a display that really
    /// refuses EDR is asked rarely instead of continuously.
    static let retryInterval: TimeInterval = 5

    private var starvedSince: TimeInterval?
    private var lastRequest: TimeInterval?

    /// `true` when the overlay should be asked for EDR again.
    mutating func shouldRequestAgain(now: TimeInterval, headroom: CGFloat, wantsBoost: Bool) -> Bool {
        guard wantsBoost, headroom < Self.starvedHeadroom else {
            starvedSince = nil
            return false
        }
        let since = starvedSince ?? now
        starvedSince = since
        guard now - since >= Self.patience else { return false }
        if let lastRequest, now - lastRequest < Self.retryInterval { return false }
        lastRequest = now
        return true
    }

    /// Forgets what was seen, for when Boost is engaged, released or held back.
    mutating func reset() {
        starvedSince = nil
        lastRequest = nil
    }
}

/// Learns what EDR headroom the panel grants when nothing throttles it, from
/// the values seen while Boost runs. A value counts only once it has held
/// steady for a moment: the headroom passes through much larger numbers while
/// the backlight is still ramping, and much smaller ones under thermal or
/// power throttling, and neither describes the panel. Pure: the caller passes
/// in the time.
struct ObservedHeadroom {
    /// How long a reading has to hold before it counts.
    static let settleTime: TimeInterval = 1.5
    /// How far a reading may wander and still count as holding.
    static let tolerance: CGFloat = 0.05

    private var candidate: CGFloat?
    private var candidateSince: TimeInterval = 0

    /// The largest settled headroom so far.
    private(set) var maximum: CGFloat?

    init(maximum: CGFloat? = nil) {
        self.maximum = maximum.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
    }

    /// Feeds one reading in. `true` when it raised `maximum`, so the caller
    /// knows to save the new value.
    @discardableResult
    mutating func record(headroom: CGFloat, now: TimeInterval) -> Bool {
        guard headroom.isFinite, headroom > 1 else {
            candidate = nil
            return false
        }
        guard let current = candidate, abs(headroom - current) <= Self.tolerance else {
            candidate = headroom
            candidateSince = now
            return false
        }
        guard now - candidateSince >= Self.settleTime else { return false }
        guard headroom > (maximum ?? 0) + Self.tolerance else { return false }
        maximum = headroom
        return true
    }
}
