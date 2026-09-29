import Foundation

/// What happened when `DisplayBrightnessProviding.apply(percentage:)` tried
/// to reach a Boost percentage (above 100%).
enum BrightnessApplyOutcome: Equatable {
    /// The requested percentage was applied as asked.
    case applied

    /// Another process already holds this display's EDR headroom — its
    /// gamma table reads back already scaled. Applying Boost on top would
    /// compound the scaling, so nothing above Nominal was touched; the
    /// caller stays clamped at 100%.
    case boostBlockedByOtherApp

    /// Reading the display's own gamma table failed before Boost could
    /// capture its baseline, so nothing was scaled or mounted. Distinct from
    /// `boostBlockedByOtherApp` so a real read failure isn't reported to the
    /// user as if another app were responsible; the caller still clamps to
    /// Nominal rather than claiming the requested percentage was reached.
    case captureFailed
}

/// Drives the built-in display's actual brightness. `@MainActor` because the
/// real implementation touches `NSScreen`/`NSWindow`/Metal, which are only
/// safe from the main thread — `BrightnessController`, its only caller, is
/// `@MainActor` itself.
@MainActor
protocol DisplayBrightnessProviding {
    func apply(percentage: Double) -> BrightnessApplyOutcome

    /// Whether this Mac's built-in display has the physical EDR headroom
    /// Boost relies on (per ADR-0003) — `false` on non-XDR Macs (e.g.
    /// MacBook Air), where Boost is a physical impossibility, not a
    /// permissions or software gap.
    func supportsExtendedBrightness() -> Bool
}

/// Disables macOS's native ambient-light-sensor-driven auto-brightness.
protocol AutoBrightnessToggling {
    func disableAutoBrightness()
}

/// The real login-item status, straight from `SMAppService.mainApp.status` —
/// `LoginItemRegistering` exposes it so `BrightnessController` can reconcile
/// its own preference against what's actually registered, rather than
/// trusting a fire-and-forget `register()` call to have worked.
enum LoginItemStatus: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

/// Registers/unregisters BrightBoi as a login item, backed by
/// `SMAppService.mainApp`. Both calls can fail (a translocated bundle, a
/// denied approval, …) — `BrightnessController` decides what to do with a
/// thrown error; this seam only reports it.
protocol LoginItemRegistering {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// Facts about where the running bundle lives, used to decide whether
/// registering a login item is safe. Background Task Management stores a
/// concrete filesystem URL for a login item — registering from anywhere
/// that URL won't still be valid next login (a bare executable, App
/// Translocation, a mounted DMG, outside /Applications) leaves a stale entry
/// behind.
protocol BundleLocationProviding {
    /// The running bundle's own path, used to detect a move (the last
    /// successfully registered path no longer matches) and to re-point the
    /// login item.
    var bundlePath: String { get }

    /// Whether the bundle lives inside an Applications folder (`/Applications`
    /// or `~/Applications`, including subfolders).
    var isInApplicationsFolder: Bool { get }

    /// Whether the bundle is running from a read-only volume or an App
    /// Translocation mount — either means the current path is a temporary
    /// artifact of this one launch, not somewhere a login item should point.
    var isTranslocatedOrReadOnly: Bool { get }
}

/// Persists the chosen brightness percentage and launch-at-login preference
/// across relaunch/reboot.
protocol BrightnessPersisting {
    func save(percentage: Double)
    func loadPercentage() -> Double?

    /// `nil` on a fresh install (nothing ever persisted), which
    /// `BrightnessController` treats as defaulting to `true` — matching
    /// today's unconditional registration behavior for upgrading users.
    func save(launchAtLoginEnabled: Bool)
    func loadLaunchAtLoginEnabled() -> Bool?

    /// The bundle path the login item was last successfully registered
    /// against — `nil` until the first successful `register()`. Lets
    /// `BrightnessController` tell "never registered" apart from "registered,
    /// then the user removed it" when the real status comes back
    /// `.notRegistered`/`.notFound`, and re-points the item after the app
    /// moves. `nil` also doubles as `BrightnessController`'s "has this copy
    /// ever registered a login item before" marker, deciding whether a
    /// missing registration is a true first attempt or a removal to respect.
    func save(lastRegisteredLoginItemPath: String)
    func loadLastRegisteredLoginItemPath() -> String?

    /// `nil` on a fresh install, which `BrightnessController` treats as
    /// defaulting to `maximumPercentage` (200%) — identical to today's fixed
    /// behavior until the user deliberately lowers it. See ADR-0004.
    func save(boostCeiling: Double)
    func loadBoostCeiling() -> Double?

    /// `nil` on a fresh install, which `BrightnessController` treats as
    /// defaulting to `.defaultShortcut` (F1/F2), matching today's behavior
    /// with no migration needed for existing users.
    func save(keyRemapShortcut: KeyRemapShortcut)
    func loadKeyRemapShortcut() -> KeyRemapShortcut?

    /// `nil` on a fresh install, which `BrightnessController` treats as
    /// defaulting to `true` — the tap starts intercepting the same as it
    /// always has, until the user turns it off.
    func save(keyRemapEnabled: Bool)
    func loadKeyRemapEnabled() -> Bool?

    /// `nil` on a fresh install, which `OnboardingModel` treats as `false` —
    /// onboarding hasn't been shown yet. Set on completion *or* skip, never
    /// on any other path, so it never re-shows once either is chosen.
    func save(hasCompletedOnboarding: Bool)
    func loadHasCompletedOnboarding() -> Bool?
}

/// Starts/stops the system-wide Key Remap tap. `RealKeyTap` supplies the real
/// `CGEventTap`-backed implementation. `onKeyPress` is how the tap reports
/// each intercepted press back to `BrightnessController` — the tap itself
/// has no reference to the controller. `@MainActor` because the real
/// implementation drives AppKit/Core Graphics event-tap state that's only
/// safe to touch from the main thread.
///
/// `start` may be called again while already running, to switch to a new
/// `remap` live (e.g. the Settings shortcut recorder) without an explicit
/// `stop` first. `stop` fully releases the tap — the configured keys return
/// to native macOS handling — used by the "Let BrightBoi own …" toggle.
@MainActor
protocol KeyTapControlling {
    func start(remap: KeyRemapShortcut, onKeyPress: @escaping (BrightnessController.KeyPress) -> Void)
    func stop()
}

/// Reports whether the Mac is currently running on battery power (not
/// connected to a power adapter), wrapping IOKit's power source APIs. Backs
/// the battery-cost advisory, which warns rather than blocks or clamps the
/// slider — draining the battery fast is the user's call to make, not
/// BrightBoi's to prevent.
protocol PowerSourceProviding {
    func isOnBatteryPower() -> Bool
}

/// Reports the system's current thermal pressure via `ProcessInfo`. Pulled
/// out as its own seam so the thermal advisory's condition is fake-able in
/// tests instead of reading a live system value directly — the advisory it
/// drives is a heuristic correlation with the requested percentage, not a
/// measurement of what the display actually delivers.
protocol ThermalStateProviding {
    func currentThermalState() -> ProcessInfo.ThermalState
}

/// Reads current Accessibility/Input Monitoring permission status, and
/// triggers macOS's own system prompt to request each one. Pulled out as its
/// own seam so the Settings panel, `RealKeyTap` (status only), and onboarding
/// (status + requesting) can all read/drive the same two permissions without
/// duplicating the raw `AXIsProcessTrusted`/`IOHIDCheckAccess`/
/// `AXIsProcessTrustedWithOptions`/`IOHIDRequestAccess` calls. Onboarding is
/// the only caller of the two `request` methods — it replaced `RealKeyTap`'s
/// previous blocking-alert-then-request flow entirely.
protocol PermissionsChecking {
    func accessibilityGranted() -> Bool
    func inputMonitoringGranted() -> Bool
    func requestAccessibility()
    func requestInputMonitoring()
}
