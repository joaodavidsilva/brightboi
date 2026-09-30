import AppKit
import CoreGraphics

/// Finds the built-in panel and reads its HDR headroom. Kept as pure
/// functions over plain values, with the CoreGraphics/AppKit reads in thin
/// wrappers, so the decisions are unit-testable without a display attached.
enum BuiltInDisplay {
    /// The built-in display's id, or `nil` when it is not online (the lid is
    /// closed in clamshell mode, or this Mac has no built-in panel).
    ///
    /// Deliberately never falls back to the main display: with an external
    /// monitor attached that would silently redirect brightness control and
    /// Boost's gamma scaling onto a screen BrightBoi must never touch.
    /// Picks from the *online* list rather than the active one — a sleeping
    /// or hardware-mirrored built-in is still the built-in, and Core
    /// Graphics documents gamma work as needing every display in use.
    static func resolveID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return builtInID(among: Array(displays.prefix(Int(count))), isBuiltIn: { CGDisplayIsBuiltin($0) != 0 })
    }

    /// Whether `displayID` is a built-in panel that can be drawn on and
    /// driven right now. A built-in panel can stay online while its lid is
    /// closed, but is then not active, and brightness control for it is
    /// meaningless. The built-in check matters because the id is cached: a
    /// stale id must never pass as an external monitor that happens to be
    /// active. Display sleep is deliberately not checked: it is not a
    /// reconfiguration, and a brightness-key press is often what wakes an idle
    /// panel.
    static func isActive(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(displayID) != 0 && CGDisplayIsOnline(displayID) != 0 && CGDisplayIsActive(displayID) != 0
    }

    /// The first display `isBuiltIn` accepts, if any.
    static func builtInID(among displays: [CGDirectDisplayID], isBuiltIn: (CGDirectDisplayID) -> Bool) -> CGDirectDisplayID? {
        displays.first(where: isBuiltIn)
    }

    /// The `NSScreen` driving `displayID`. `NSScreen.screens` lists only
    /// displays that are active and drawable, so this is `nil` for an
    /// offline or asleep display even when `displayID` itself is still known.
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screenNumber(of: $0) == displayID }
    }

    static func screenNumber(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// HDR headroom facts Boost is gated and clamped on.
///
/// Two different `NSScreen` properties are involved, and mixing them up was
/// the reason Boost used to be missing on an idle XDR MacBook Pro:
/// - `maximumPotentialExtendedDynamicRangeColorComponentValue` is what the
///   panel *could* offer if something asked for EDR. It is a property of the
///   hardware (16.0 on the XDR panel, 1.0 on an ordinary one) and is stable.
/// - `maximumExtendedDynamicRangeColorComponentValue` is what is granted
///   *right now*. It sits at 1.0 until some window on screen requests EDR
///   and ramps up over about a second afterwards, so it says nothing about
///   whether Boost is possible.
enum BoostHeadroom {
    /// The smallest potential headroom that can carry the full Boost range.
    /// 200% brightness is a gamma factor of 2.0, so a panel that cannot
    /// reach 2.0x SDR white has nothing to boost into. The XDR panel reports
    /// 16.0; an ordinary panel reports 1.0. A panel that overstates its
    /// potential is still safe, because `effectiveFactor` never scales past
    /// the headroom actually granted.
    static let minimumPotentialForBoost: CGFloat = 2.0

    /// A change in granted headroom smaller than this is not worth
    /// rewriting the gamma table for.
    static let headroomChangeTolerance: CGFloat = 0.02

    /// Whether a panel reporting `potential` headroom can boost. `nil`
    /// (no screen, or a value that cannot be read) is "no".
    static func hasBoostHeadroom(potential: CGFloat?) -> Bool {
        guard let potential, potential.isFinite else { return false }
        return potential >= minimumPotentialForBoost
    }

    /// The gamma factor to actually write: `requested`, but never more than
    /// the EDR headroom the display currently grants (in table-factor terms,
    /// so a gamma-encoded table is clamped to the headroom's matching root). Scaling past the
    /// headroom clips every highlight to white instead of making the screen
    /// brighter, so while the headroom is still ramping up (or has been
    /// throttled) Boost delivers less rather than clipping. Never below 1.0,
    /// which is the identity table.
    static func effectiveFactor(requested: CGFloat, headroom: CGFloat, domain: GammaDomain = .assumed) -> CGFloat {
        guard requested.isFinite, headroom.isFinite else { return 1 }
        let headroomFactor = CGFloat(domain.tableFactor(forLuminanceRatio: Double(headroom)))
        return max(1, min(requested, headroomFactor))
    }

    /// Whether a new effective factor differs enough from the one already
    /// written to justify rewriting the table.
    static func shouldRewrite(from written: CGFloat, to proposed: CGFloat) -> Bool {
        abs(proposed - written) >= headroomChangeTolerance
    }

    /// Boost support for a panel whose potential headroom reads `potential`.
    /// While the panel has no `NSScreen` for a moment (display sleep or
    /// wake) `potential` is `nil` and the last verdict is kept, so a
    /// momentary gap does not read as "this panel can no longer boost".
    /// With nothing to fall back on, an unreadable panel cannot boost.
    static func boostSupport(potential: CGFloat?, previousVerdict: Bool?) -> Bool {
        if potential == nil, let previousVerdict { return previousVerdict }
        return hasBoostHeadroom(potential: potential)
    }

    /// The live and potential headroom of `displayID`'s screen, or `nil`
    /// when it has no `NSScreen`.
    @MainActor
    static func read(displayID: CGDirectDisplayID) -> (current: CGFloat, potential: CGFloat)? {
        guard let screen = BuiltInDisplay.screen(for: displayID) else { return nil }
        return (
            screen.maximumExtendedDynamicRangeColorComponentValue,
            screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        )
    }
}
