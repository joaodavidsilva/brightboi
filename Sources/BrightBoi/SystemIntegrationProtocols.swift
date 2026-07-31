import Foundation

/// Drives the built-in display's actual brightness. Ticket 04/05 supply the
/// real implementation (private/EDR techniques per `docs/brightness-api-research.md`);
/// this ticket only defines the seam.
protocol DisplayBrightnessProviding {
    func apply(percentage: Double)

    /// Whether this Mac's built-in display has the physical EDR headroom
    /// Boost relies on (per ADR-0003) — `false` on non-XDR Macs (e.g.
    /// MacBook Air), where Boost is a physical impossibility, not a
    /// permissions or software gap.
    func supportsExtendedBrightness() -> Bool
}

/// Disables macOS's native ambient-light-sensor-driven auto-brightness.
/// Ticket 06 supplies the real implementation.
protocol AutoBrightnessToggling {
    func disableAutoBrightness()
}

/// Registers/unregisters BrightBoi as a login item. Ticket 08 supplies the
/// real `SMAppService`-backed implementation.
protocol LoginItemRegistering {
    func registerForLaunchAtLogin()

    /// Removes BrightBoi from System Settings' Login Items, for when the
    /// user unchecks the launch-at-login preference.
    func unregisterFromLaunchAtLogin()
}

/// Persists the chosen brightness percentage and launch-at-login preference
/// across relaunch/reboot. Ticket 08 supplies the real `UserDefaults`-backed
/// implementation.
protocol BrightnessPersisting {
    func save(percentage: Double)
    func loadPercentage() -> Double?

    /// `nil` on a fresh install (nothing ever persisted), which
    /// `BrightnessController` treats as defaulting to `true` — matching
    /// today's unconditional registration behavior for upgrading users.
    func save(launchAtLoginEnabled: Bool)
    func loadLaunchAtLoginEnabled() -> Bool?

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
/// has no reference to the controller.
///
/// `start` may be called again while already running, to switch to a new
/// `remap` live (e.g. the Settings shortcut recorder) without an explicit
/// `stop` first. `stop` fully releases the tap — the configured keys return
/// to native macOS handling — used by the "Let BrightBoi own …" toggle.
protocol KeyTapControlling {
    func start(remap: KeyRemapShortcut, onKeyPress: @escaping (BrightnessController.KeyPress) -> Void)
    func stop()
}

/// Reads current Accessibility/Input Monitoring permission status, and
/// triggers macOS's own system prompt to request each one. Pulled out as its
/// own seam so the Settings panel, `RealKeyTap` (status only), and onboarding
/// (status + requesting) can all read/drive the same two permissions without
/// duplicating the raw `AXIsProcessTrusted`/`IOHIDCheckAccess`/
/// `AXIsProcessTrustedWithOptions`/`IOHIDRequestAccess` calls. Onboarding
/// (ticket 04) is the only caller of the two `request` methods — it replaced
/// `RealKeyTap`'s previous blocking-alert-then-request flow entirely.
protocol PermissionsChecking {
    func accessibilityGranted() -> Bool
    func inputMonitoringGranted() -> Bool
    func requestAccessibility()
    func requestInputMonitoring()
}
