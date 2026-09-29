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

    /// The display's live Nominal brightness (0...100), read straight from
    /// the system rather than from anything BrightBoi itself last wrote —
    /// `nil` when it can't be read (e.g. clamshell mode resolving to the
    /// external display). Used both to adopt the user's current level on a
    /// fresh install, instead of jumping to a fixed default, and to notice a
    /// brightness change made outside BrightBoi (Control Center, a native
    /// key press with Key Remap off, macOS's own dimming).
    func currentNominalPercentage() -> Double?

    /// Releases Boost's gamma scaling and EDR headroom without writing
    /// Nominal brightness — the "someone else already set Nominal, Boost
    /// just needs to get out of the way" half of adopting an external
    /// brightness change. Distinct from `apply(percentage:)` with a
    /// Nominal-range value, which would also rewrite the Nominal brightness
    /// itself and could fight a Control Center drag still in progress.
    func adoptExternalNominal()
}

/// Disables/restores macOS's native ambient-light-sensor-driven
/// auto-brightness, and reports whether it's currently on — used to record
/// the user's real setting before BrightBoi's takeover so it can be put
/// back exactly as found on quit.
protocol AutoBrightnessToggling {
    func disableAutoBrightness()

    /// Restores macOS's own ambient-light-sensor-driven auto-brightness —
    /// the inverse of `disableAutoBrightness()`, used to give control back
    /// on quit (and when the user turns off BrightBoi's takeover in
    /// Settings).
    func enableAutoBrightness()

    /// The system's real current setting for "Automatically adjust
    /// brightness", read fresh (not cached) — `nil` only if the underlying
    /// private symbol couldn't be loaded at all. An absent preference key is
    /// reported as `true`: that's the macOS default on a Mac where the
    /// checkbox was never touched, and treating it as `false` would mean
    /// quitting never restores that default.
    func isAutoBrightnessEnabled() -> Bool?
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

    /// Whether macOS's own auto-brightness was on right before BrightBoi's
    /// takeover disabled it — recorded once per continuous run (see
    /// `loadAutoBrightnessWasEnabledOriginally`), so quitting can put it back
    /// exactly as found.
    func save(autoBrightnessWasEnabledOriginally: Bool)

    /// `nil` until the first time this is recorded in a session that hasn't
    /// yet cleared it — `BrightnessController` only ever writes this once
    /// per continuous run (guarded by this being `nil`), so a crash between
    /// disabling auto-brightness and restoring it on quit can't have the
    /// *next* launch overwrite the true original with the now-disabled
    /// value it would otherwise read.
    func loadAutoBrightnessWasEnabledOriginally() -> Bool?

    /// Called after successfully restoring the original on a clean quit, so
    /// the next launch records a fresh "original" rather than continuing to
    /// protect a value that's already been put back.
    func clearAutoBrightnessWasEnabledOriginally()

    /// The Settings toggle "Turn off macOS auto-brightness while BrightBoi
    /// runs". `nil` on a fresh install, which `BrightnessController` treats
    /// as `true` — matching today's unconditional takeover for existing
    /// users.
    func save(autoBrightnessTakeoverEnabled: Bool)
    func loadAutoBrightnessTakeoverEnabled() -> Bool?
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
/// connected to a power adapter) and whether Low Power Mode is on, wrapping
/// IOKit's power source APIs and `ProcessInfo`. Backs the battery-cost and
/// Low Power Mode advisories, which warn rather than block or clamp the
/// slider — draining the battery fast is the user's call to make, not
/// BrightBoi's to prevent. `@MainActor` because the real implementation's
/// observer setup/teardown (a `CFRunLoopSource` on the main run loop, an
/// `NSObjectProtocol` token) is only ever driven from `BrightnessController`.
@MainActor
protocol PowerSourceProviding {
    func isOnBatteryPower() -> Bool

    /// Apple documents Low Power Mode as reducing screen brightness among
    /// its energy-saving measures — independent of `isOnBatteryPower()`,
    /// since pmset keeps a separate power mode per power source and Low
    /// Power Mode can be on while plugged in.
    func isLowPowerModeEnabled() -> Bool

    /// Calls `onChange` after either kind of power-state event this
    /// protocol reports on — an IOKit power-source change (plug/unplug, a
    /// charge-percentage tick) or Low Power Mode flipping. The caller
    /// re-reads whichever of `isOnBatteryPower()`/`isLowPowerModeEnabled()`
    /// it cares about itself; this only signals "something changed, go
    /// re-check" rather than describing what changed.
    func startObserving(_ onChange: @escaping () -> Void)
}

/// Reports the system's current thermal pressure via `ProcessInfo`. Pulled
/// out as its own seam so the thermal advisory's condition is fake-able in
/// tests instead of reading a live system value directly — the advisory it
/// drives is a heuristic correlation with the requested percentage, not a
/// measurement of what the display actually delivers. `@MainActor` for the
/// same reason as `PowerSourceProviding`.
@MainActor
protocol ThermalStateProviding {
    func currentThermalState() -> ProcessInfo.ThermalState

    /// Calls `onChange` whenever `currentThermalState()` may have changed —
    /// the caller re-reads it rather than being told the new value directly.
    func startObserving(_ onChange: @escaping () -> Void)
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
