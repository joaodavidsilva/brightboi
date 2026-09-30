import CoreGraphics
import Foundation

/// Another app is taking the brightness keys before BrightBoi sees them.
/// Only one app can own those keys, and the app whose event tap was created
/// last sees them first, so launch order decides who wins.
struct KeyTapConflict: Equatable {
    /// The app that looks responsible, or `nil` when it cannot be told apart
    /// from other apps that also watch system-defined events.
    var appName: String?

    /// What Settings tells the user.
    var message: String {
        let who = appName ?? "Another app"
        let subject = appName ?? "that app"
        return "\(who) is intercepting the brightness keys, so BrightBoi isn't receiving them. Turn off brightness-key handling in \(subject), or turn this off."
    }
}

/// What `CGGetEventTapList` reports about one installed event tap.
struct EventTapSnapshot: Equatable {
    var processID: pid_t
    /// An active filter that can swallow events, rather than a listen-only tap.
    var isActiveFilter: Bool
    var isEnabled: Bool
    var eventsOfInterest: UInt64
}

/// Picks the app to name in a `KeyTapConflict`, from the installed taps.
/// Best effort: the tap list says which events a tap sees, not which keys it
/// swallows, so it can only narrow the field.
enum KeyTapConflictResolver {
    /// The event-mask bit of `NX_SYSDEFINED`, where media keys arrive.
    static let systemDefinedBit: UInt64 = 1 << 14

    /// Apps known to take over the brightness keys.
    static let knownBundleIdentifiers: Set<String> = [
        "app.monitorcontrol.MonitorControl",
        "fyi.lunar.Lunar",
        "pro.betterdisplay.BetterDisplay",
        "com.hegenberg.BetterTouchTool"
    ]

    /// Taps that could be swallowing brightness keys: active, enabled, watching
    /// system-defined events, and not owned by `ownProcessID`. The key-down bit
    /// is deliberately not considered; it would match unrelated taps.
    static func candidates(in taps: [EventTapSnapshot], ownProcessID: pid_t) -> [EventTapSnapshot] {
        taps.filter {
            $0.isActiveFilter
                && $0.isEnabled
                && $0.eventsOfInterest & systemDefinedBit != 0
                && $0.processID != ownProcessID
        }
    }

    /// The process to name: the only candidate, or failing that the only
    /// candidate that is a known brightness-key tool. `nil` when that is
    /// ambiguous.
    static func namedProcessID(
        in taps: [EventTapSnapshot],
        ownProcessID: pid_t,
        bundleIdentifier: (pid_t) -> String?
    ) -> pid_t? {
        let candidates = Set(candidates(in: taps, ownProcessID: ownProcessID).map(\.processID))
        if candidates.count == 1 { return candidates.first }
        let known = candidates.filter { bundleIdentifier($0).map(knownBundleIdentifiers.contains) ?? false }
        return known.count == 1 ? known.first : nil
    }
}

/// Notices a brightness key that BrightBoi's own tap never received. A
/// listen-only tap at the HID level sees a key press before any session tap,
/// so a press seen there but not by BrightBoi's tap was swallowed in between.
struct KeyInterceptionMonitor {
    private var pending: Set<UInt64> = []

    /// A brightness key BrightBoi claims was seen at the HID level.
    mutating func observedAtHID(timestamp: UInt64) {
        pending.insert(timestamp)
    }

    /// BrightBoi's own tap received the press with this timestamp.
    mutating func receivedByTap(timestamp: UInt64) {
        pending.remove(timestamp)
    }

    /// Called once the tap had time to receive the press. `true` when it
    /// never did, meaning another tap consumed it.
    mutating func wasIntercepted(timestamp: UInt64) -> Bool {
        pending.remove(timestamp) != nil
    }
}
