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

    /// There is no built-in display to drive (lid closed, or none online),
    /// or the EDR overlay could not be mounted on its screen. Nothing was
    /// changed, and the caller stays clamped at Nominal. Never redirected to
    /// another display.
    case displayUnavailable
}

/// Drives the built-in display's actual brightness. `@MainActor` because the
/// real implementation touches `NSScreen`/`NSWindow`/Metal, which are only
/// safe from the main thread — `BrightnessController`, its only caller, is
/// `@MainActor` itself.
@MainActor
protocol DisplayBrightnessProviding {
    func apply(percentage: Double) -> BrightnessApplyOutcome

    /// Whether the built-in display can boost right now: it is online, and
    /// its panel *could* offer the EDR headroom Boost needs (its potential
    /// headroom, not what is granted at this moment — that stays at 1.0
    /// until something asks for EDR). `false` on non-XDR Macs (e.g. MacBook
    /// Air), and while the built-in display is not online. Can change during
    /// a session; see `onDisplayConfigurationChange`.
    func supportsExtendedBrightness() -> Bool

    /// Whether a built-in display is online and active. Brightness control is
    /// unavailable while it isn't — it is never redirected to an external
    /// monitor.
    var isBuiltInDisplayAvailable: Bool { get }

    /// Whether Nominal (0–100%) brightness can be set right now. Re-read on
    /// demand, since a display preset can lock it and unlock it again.
    var nominalControl: NominalControlStatus { get }

    /// Called after the display configuration changed in a way that affects
    /// `isBuiltInDisplayAvailable`, `supportsExtendedBrightness()` or
    /// `nominalControl`: the built-in display appeared or disappeared (lid,
    /// hot-plug), or its identity or capability changed. Never called before the first
    /// configuration change.
    var onDisplayConfigurationChange: (() -> Void)? { get set }

    /// The display's live Nominal brightness (0...100), read straight from
    /// the system rather than from anything BrightBoi itself last wrote —
    /// `nil` when it can't be read (e.g. no built-in display is online,
    /// or the symbol is unavailable). Used both to adopt the user's current level on a
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
    /// behavior until the user deliberately lowers it.
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

/// Starts/stops the system-wide Key Remap. `RealKeyTap` supplies the real
/// implementation: an event tap for the bare brightness keys and system hot
/// keys for custom combos. `onKeyPress` is how it reports each intercepted
/// press back to `BrightnessController`, which it has no reference to.
/// `@MainActor` because the real implementation drives AppKit/Core Graphics
/// event state that is only safe to touch from the main thread.
///
/// `start` may be called again while already running, to switch to a new
/// `remap` live (e.g. the Settings shortcut recorder) without an explicit
/// `stop` first, and to retry after a failed attempt (the permission it needs
/// was granted since). `stop` fully releases everything: the configured keys
/// return to native macOS handling, used by the "Let BrightBoi own …" toggle.
@MainActor
protocol KeyTapControlling {
    /// `onKeyPress` returns whether BrightBoi took the press. `false` lets
    /// the event through untouched, so macOS handles the key itself.
    func start(remap: KeyRemapShortcut, onKeyPress: @escaping (BrightnessController.KeyPress) -> Bool)
    func stop()

    /// Whether everything the started remap needs is installed and working.
    /// `false` after a `start` that could not install its event tap (the
    /// Accessibility permission is missing, for instance), so the failure is
    /// visible instead of the keys silently staying with macOS.
    var isActive: Bool { get }

    /// Another app that takes the brightness keys before BrightBoi sees
    /// them, when one was noticed. Best effort.
    var conflict: KeyTapConflict? { get }

    /// Calls `onChange` whenever `conflict` changes.
    func observeConflicts(_ onChange: @escaping () -> Void)
}

/// Reads the accessibility display options that change how the display's
/// transfer table is read, and reports when they change. Only Invert Colors
/// is exposed: it has a public signal, while Color Filters do not.
/// `@MainActor` because the real implementation reads AppKit state.
@MainActor
protocol DisplayAccessibilityProviding {
    /// Whether the system inverts the display's colours.
    var invertsColors: Bool { get }

    /// Calls `onChange` when an accessibility display option changed; the
    /// caller re-reads what it cares about.
    func startObserving(_ onChange: @escaping () -> Void)
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

/// What macOS knows about a permission BrightBoi asked for.
enum PermissionAccess: Equatable {
    case granted
    /// The user turned it down, or never switched it on after a prompt.
    case denied
    /// macOS has no answer yet, so a request shows the system prompt.
    case unknown
}

/// Reads current Accessibility/Input Monitoring permission status, and
/// triggers macOS's own system prompt to request each one. Pulled out as its
/// own seam so `PermissionsModel` can read and request the same permissions
/// the key tap depends on without duplicating the raw
/// `AXIsProcessTrusted`/`IOHIDCheckAccess`/`AXIsProcessTrustedWithOptions`/
/// `IOHIDRequestAccess` calls. The status reads are cheap and never prompt.
protocol PermissionsChecking {
    func accessibilityGranted() -> Bool
    func inputMonitoringAccess() -> PermissionAccess
    func requestAccessibility()
    func requestInputMonitoring()
}
