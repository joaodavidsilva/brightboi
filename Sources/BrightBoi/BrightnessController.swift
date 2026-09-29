import AppKit
import Foundation
import Observation

/// The single seam the whole app is built around. Internally depends only on
/// small protocols for every system-facing effect (`DisplayBrightnessProviding`,
/// `AutoBrightnessToggling`, `LoginItemRegistering`, `BrightnessPersisting`,
/// `KeyTapControlling`, `BundleLocationProviding`) — this keeps every real
/// system effect fake-able in tests.
///
/// `@Observable` so the menu bar UI (slider, live icon) re-renders as
/// `currentState` changes, without needing a separate published wrapper.
///
/// `@MainActor`: every real implementation behind these protocols — AppKit
/// windows, a `CGEventTap`, Metal — is main-thread-only, and every call site
/// (SwiftUI, the key tap's callback, `AppDelegate`) already only ever drives
/// this from the main thread. Isolating the type turns that implicit
/// invariant into a compile-time guarantee instead of a runtime trap.
@MainActor
@Observable
final class BrightnessController {
    /// Percentage bounds per the spec: 0–100 is Nominal Brightness,
    /// 100–200 is Extended Brightness / Boost. `nonisolated` because these
    /// are read from plain data code with no main-thread requirement of its
    /// own — `RealBrightnessPersistence`'s fresh-install fallback,
    /// `LiveDisplayBrightnessProvider`'s math, and the popover/Settings/HUD
    /// views.
    nonisolated static let minimumPercentage: Double = 0
    nonisolated static let maximumPercentage: Double = 200
    nonisolated static let nominalCeilingPercentage: Double = 100
    nonisolated static let percentageGranularity: Double = 5

    /// Absolute threshold on the 0...200 scale, not relative to a lowered
    /// Boost Ceiling — if the ceiling is already below this, the battery
    /// advisory simply never fires. See the spec's Battery advisory decision.
    nonisolated static let batteryAdvisoryThresholdPercentage: Double = 170

    /// The thermal advisory's heuristic "delivered %" offsets — see
    /// ADR-0005: not a measurement, just how far below the requested
    /// percentage each thermal state is assumed to land.
    nonisolated static let thermalSeriousDeliveredOffset: Double = 20
    nonisolated static let thermalCriticalDeliveredOffset: Double = 40

    private static let moveToApplicationsMessage = "Move BrightBoi to Applications to launch at login."

    struct State: Equatable {
        var percentage: Double
        var isBoosted: Bool
        var iconFillFraction: Double
        var supportsBoost: Bool
        var launchAtLoginEnabled: Bool
        var launchAtLoginNeedsApproval: Bool
        var launchAtLoginStatusMessage: String?
        var boostCeiling: Double
        var keyRemapEnabled: Bool
        var keyRemapShortcut: KeyRemapShortcut

        /// `true` once an attempt to go past 100% was refused because
        /// another process already holds this display's EDR headroom — see
        /// `BoostEngagement`'s capture guard. Reset on the next attempt,
        /// whether or not it succeeds.
        var boostBlockedByOtherApp: Bool

        /// 5 nits per percentage point — 100% is the old 500-nit Nominal
        /// ceiling, 200% is the 1000-nit Boost ceiling, per ADR-0002.
        var nits: Double { percentage * 5 }

        /// Same 5-nits-per-point conversion, applied to the configured Boost
        /// Ceiling rather than the live percentage — what Settings' "Don't
        /// let me go past" row shows.
        var boostCeilingNits: Double { boostCeiling * 5 }
    }

    enum KeyPress {
        case raise
        case lower
    }

    /// The thermal-throttle advisory's content — see ADR-0005: `deliveredPercentage`
    /// is a heuristic estimate (`.serious` → requested − 20, `.critical` →
    /// requested − 40), never a measurement.
    struct ThermalAdvisory: Equatable {
        var requestedPercentage: Double
        var deliveredPercentage: Double
    }

    private(set) var currentState: State

    /// Notified after every recognized key press is applied — including a
    /// press that clamps at the 0%/200% ends and so leaves the percentage
    /// unchanged — with the state as of right after that press. Passing
    /// `State` through the callback (rather than the caller reading
    /// `currentState` back off the controller) means whoever wires this up
    /// doesn't need to capture the controller itself just to read its state.
    @ObservationIgnored
    var onKeyPress: ((KeyPress, State) -> Void)?

    private let displayBrightness: DisplayBrightnessProviding
    private let autoBrightnessToggle: AutoBrightnessToggling
    private let loginItemService: LoginItemRegistering
    private let persistence: BrightnessPersisting
    private let keyTap: KeyTapControlling
    private let powerSource: PowerSourceProviding
    private let thermalState: ThermalStateProviding
    private let bundleLocation: BundleLocationProviding

    private let keyStepPercentage: Double
    private let persistenceDebounceInterval: TimeInterval
    private let supportsBoost: Bool
    private var boostCeiling: Double
    private var keyRemapEnabled: Bool
    private var keyRemapShortcut: KeyRemapShortcut
    private var hasStarted = false
    private var lastLaunchAtLoginError: String?
    @ObservationIgnored
    private var pendingPersistWorkItem: DispatchWorkItem?

    /// Builds the controller and its initial `currentState` from whatever's
    /// already persisted — no side effect touches the display, the login
    /// item list, auto-brightness or the key tap. That happens once in
    /// `start()`, so constructing the controller early (SwiftUI's
    /// `MenuBarExtra`/`Settings` scenes need it at `body` time, before the
    /// app has finished launching) is always safe.
    init(
        displayBrightness: DisplayBrightnessProviding,
        autoBrightnessToggle: AutoBrightnessToggling,
        loginItemService: LoginItemRegistering,
        persistence: BrightnessPersisting,
        keyTap: KeyTapControlling,
        powerSource: PowerSourceProviding,
        thermalState: ThermalStateProviding,
        bundleLocation: BundleLocationProviding,
        keyStepPercentage: Double = percentageGranularity,
        persistenceDebounceInterval: TimeInterval = 0.3
    ) {
        self.displayBrightness = displayBrightness
        self.autoBrightnessToggle = autoBrightnessToggle
        self.loginItemService = loginItemService
        self.persistence = persistence
        self.keyTap = keyTap
        self.powerSource = powerSource
        self.thermalState = thermalState
        self.bundleLocation = bundleLocation
        self.keyStepPercentage = keyStepPercentage
        self.persistenceDebounceInterval = persistenceDebounceInterval

        // Session-start-only check, decided once here and never re-read —
        // Boost availability can't change mid-session, since it depends on
        // the built-in display's fixed physical headroom.
        let supportsBoost = displayBrightness.supportsExtendedBrightness()
        self.supportsBoost = supportsBoost

        // `nil` (fresh install) defaults to `maximumPercentage`, identical
        // to today's fixed 200% ceiling until deliberately lowered.
        let boostCeiling = Self.clampedBoostCeiling(persistence.loadBoostCeiling() ?? Self.maximumPercentage)
        self.boostCeiling = boostCeiling

        let keyRemapEnabled = persistence.loadKeyRemapEnabled() ?? true
        self.keyRemapEnabled = keyRemapEnabled

        let keyRemapShortcut = persistence.loadKeyRemapShortcut() ?? .defaultShortcut
        self.keyRemapShortcut = keyRemapShortcut

        let boostAwareCeiling = supportsBoost ? boostCeiling : Self.nominalCeilingPercentage
        let restoredPercentage = Self.resolvedPercentage(persistence.loadPercentage() ?? Self.minimumPercentage, effectiveMaximum: boostAwareCeiling)
        // `nil` (fresh install) defaults to `true`, matching the app's
        // previous unconditional registration behavior for upgrading users.
        // `start()` reconciles this against the real login-item status
        // before it ever reaches a view.
        let launchAtLoginEnabled = persistence.loadLaunchAtLoginEnabled() ?? true
        self.currentState = Self.state(
            for: restoredPercentage,
            supportsBoost: supportsBoost,
            launchAtLoginEnabled: launchAtLoginEnabled,
            launchAtLoginNeedsApproval: false,
            launchAtLoginStatusMessage: nil,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut,
            boostBlockedByOtherApp: false
        )
    }

    /// Fires every session-start-only side effect exactly once: applies the
    /// restored percentage to the real display, disables macOS's native
    /// auto-brightness, reconciles/attempts login-item registration, and
    /// starts the key tap. Called from
    /// `AppDelegate.applicationDidFinishLaunching`, once `NSApp` has
    /// actually finished launching. Calling it again is a no-op.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        applyToDisplay(percentage: currentState.percentage)
        autoBrightnessToggle.disableAutoBrightness()
        syncLaunchAtLoginAtStart()
        if keyRemapEnabled {
            startKeyTap(remap: keyRemapShortcut)
        }
    }

    func setPercentage(_ percentage: Double) {
        let resolved = Self.resolvedPercentage(percentage, effectiveMaximum: currentEffectiveMaximum)
        applyToDisplay(percentage: resolved)
        schedulePersist(currentState.percentage)
    }

    func handleKeyPress(_ press: KeyPress) {
        let delta = press == .raise ? keyStepPercentage : -keyStepPercentage
        setPercentage(currentState.percentage + delta)
        onKeyPress?(press, currentState)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        persistence.save(launchAtLoginEnabled: enabled)
        if enabled {
            if bundleLocation.isInApplicationsFolder, !bundleLocation.isTranslocatedOrReadOnly {
                do {
                    try loginItemService.register()
                    persistence.save(lastRegisteredLoginItemPath: bundleLocation.bundlePath)
                } catch {
                    lastLaunchAtLoginError = error.localizedDescription
                }
            }
        } else {
            do {
                try loginItemService.unregister()
            } catch {
                lastLaunchAtLoginError = error.localizedDescription
            }
        }
        refreshLaunchAtLoginStatus()
    }

    /// Re-reads the real login-item status and derives every launch-at-login
    /// field in `currentState` from it, rather than trusting the last call
    /// this controller happened to make — System Settings' Login Items list
    /// can change BrightBoi's registration (approval, removal) without
    /// BrightBoi hearing about it directly. Call from Settings' `onAppear`
    /// and whenever the app becomes active, since neither alone is reliable:
    /// SwiftUI doesn't always re-run `onAppear` when Settings is reopened,
    /// and this accessory app is rarely the active one.
    func refreshLaunchAtLoginStatus() {
        let status = loginItemService.status
        let message = lastLaunchAtLoginError ?? locationNotice(for: status)
        lastLaunchAtLoginError = nil

        currentState = Self.state(
            for: currentState.percentage,
            supportsBoost: supportsBoost,
            launchAtLoginEnabled: status == .enabled || status == .requiresApproval,
            launchAtLoginNeedsApproval: status == .requiresApproval,
            launchAtLoginStatusMessage: message,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut,
            boostBlockedByOtherApp: currentState.boostBlockedByOtherApp
        )
    }

    /// Bounded `[100, 200]` per ADR-0004 — the floor keeps an accidental drag
    /// from blacking out the screen, the ceiling is the hard maximum
    /// ADR-0002 already established. Lowering it below the current live
    /// brightness clamps brightness down immediately, via the `setPercentage`
    /// re-resolve below.
    func setBoostCeiling(_ percentage: Double) {
        let clamped = Self.clampedBoostCeiling(percentage)
        boostCeiling = clamped
        persistence.save(boostCeiling: clamped)
        currentState = updatedState(percentage: currentState.percentage)
        if currentState.percentage > clamped {
            setPercentage(currentState.percentage)
        }
    }

    /// Off fully releases the tap — the configured keys return to native
    /// macOS handling. On reinstalls it with the currently configured combo.
    func setKeyRemapEnabled(_ enabled: Bool) {
        keyRemapEnabled = enabled
        persistence.save(keyRemapEnabled: enabled)
        currentState = updatedState(percentage: currentState.percentage)
        if enabled {
            startKeyTap(remap: keyRemapShortcut)
        } else {
            keyTap.stop()
        }
    }

    /// Restarts the tap live with the new combo when the remap is currently
    /// enabled; when disabled, just persists the new combo for next time it's
    /// turned on.
    func setKeyRemapShortcut(_ shortcut: KeyRemapShortcut) {
        keyRemapShortcut = shortcut
        persistence.save(keyRemapShortcut: shortcut)
        currentState = updatedState(percentage: currentState.percentage)
        if keyRemapEnabled {
            startKeyTap(remap: shortcut)
        }
    }

    /// Advisory only — never blocks or clamps the slider. Read fresh on every
    /// access (not cached in `currentState`), since power-source state can
    /// change without any brightness change to trigger a state rebuild.
    var batteryAdvisoryVisible: Bool {
        currentState.percentage > Self.batteryAdvisoryThresholdPercentage && powerSource.isOnBatteryPower()
    }

    /// `nil` unless boosted and the system is under thermal pressure.
    /// Advisory only — never blocks or clamps the slider. Read fresh on every
    /// access for the same reason as `batteryAdvisoryVisible` above.
    var thermalAdvisory: ThermalAdvisory? {
        guard currentState.isBoosted else { return nil }
        let requested = currentState.percentage
        switch thermalState.currentThermalState() {
        case .serious:
            return ThermalAdvisory(requestedPercentage: requested, deliveredPercentage: requested - Self.thermalSeriousDeliveredOffset)
        case .critical:
            return ThermalAdvisory(requestedPercentage: requested, deliveredPercentage: requested - Self.thermalCriticalDeliveredOffset)
        case .nominal, .fair:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Flushes any pending debounced save immediately — internal (not
    /// private) so `AppDelegate.applicationWillTerminate` can call it
    /// directly. The debounce window (default 0.3s) would otherwise drop the
    /// final percentage if the user quits right after their last
    /// slider/key move.
    func flushPendingPersist() {
        guard let pendingPersistWorkItem else { return }
        pendingPersistWorkItem.cancel()
        persistence.save(percentage: currentState.percentage)
        self.pendingPersistWorkItem = nil
    }

    private func startKeyTap(remap: KeyRemapShortcut) {
        keyTap.start(remap: remap) { [weak self] press in
            self?.handleKeyPress(press)
        }
    }

    /// Applies `percentage` to the real display and folds the outcome into
    /// `currentState`. Any outcome other than `.applied` — another process
    /// already holding this display's EDR headroom, or a failed gamma
    /// capture — clamps the displayed percentage down to Nominal's 100%
    /// ceiling rather than showing a number the display never actually
    /// reached; only the former also raises the "another app" banner, since
    /// a capture failure isn't caused by another app.
    private func applyToDisplay(percentage: Double) {
        let outcome = displayBrightness.apply(percentage: percentage)
        let blockedByOtherApp = outcome == .boostBlockedByOtherApp
        let effectivePercentage = outcome == .applied ? percentage : min(percentage, Self.nominalCeilingPercentage)
        currentState = updatedState(percentage: effectivePercentage, boostBlockedByOtherApp: blockedByOtherApp)
    }

    // MARK: - Launch at login

    /// Called once from `start()`. `currentState.launchAtLoginEnabled` is
    /// always derived fresh from `loginItemService.status` afterwards (see
    /// `refreshLaunchAtLoginStatus`), so this only decides whether to *act*:
    /// register when this copy has never successfully registered before
    /// (a true first launch, or an earlier attempt withheld by location),
    /// re-point the item if the bundle moved since it last registered, or —
    /// if it was registered before and is gone now — treat that as the user
    /// having removed it in System Settings, not as something to silently
    /// undo on every subsequent launch.
    private func syncLaunchAtLoginAtStart() {
        guard persistence.loadLaunchAtLoginEnabled() ?? true else {
            refreshLaunchAtLoginStatus()
            return
        }

        switch loginItemService.status {
        case .enabled, .requiresApproval:
            repointLoginItemIfBundleMoved()
        case .notRegistered, .notFound:
            if persistence.loadLastRegisteredLoginItemPath() == nil {
                attemptRegistration()
            } else {
                persistence.save(launchAtLoginEnabled: false)
            }
        @unknown default:
            break
        }

        refreshLaunchAtLoginStatus()
    }

    /// Never registers from a bare executable, App Translocation, a mounted
    /// DMG, or anywhere outside an Applications folder — Background Task
    /// Management stores a concrete URL for the login item, and none of
    /// those paths still exist next login.
    @discardableResult
    private func attemptRegistration() -> Bool {
        guard bundleLocation.isInApplicationsFolder, !bundleLocation.isTranslocatedOrReadOnly else { return false }
        do {
            try loginItemService.register()
            persistence.save(lastRegisteredLoginItemPath: bundleLocation.bundlePath)
            return true
        } catch {
            lastLaunchAtLoginError = error.localizedDescription
            return false
        }
    }

    private func repointLoginItemIfBundleMoved() {
        guard bundleLocation.isInApplicationsFolder, !bundleLocation.isTranslocatedOrReadOnly,
              let lastPath = persistence.loadLastRegisteredLoginItemPath(), lastPath != bundleLocation.bundlePath else { return }
        do {
            try loginItemService.unregister()
            try loginItemService.register()
            persistence.save(lastRegisteredLoginItemPath: bundleLocation.bundlePath)
        } catch {
            lastLaunchAtLoginError = error.localizedDescription
        }
    }

    /// The explanatory line Settings shows under the switch while the user
    /// wants launch-at-login on but BrightBoi is withholding registration
    /// because of where it's currently running from.
    private func locationNotice(for status: LoginItemStatus) -> String? {
        guard status == .notRegistered || status == .notFound else { return nil }
        guard persistence.loadLaunchAtLoginEnabled() ?? true else { return nil }
        guard !(bundleLocation.isInApplicationsFolder && !bundleLocation.isTranslocatedOrReadOnly) else { return nil }
        return Self.moveToApplicationsMessage
    }

    /// The ceiling `setPercentage`/key presses actually clamp against: the
    /// user's configured Boost Ceiling on an XDR Mac, or the fixed Nominal
    /// ceiling on a non-XDR Mac where Boost — and therefore a configurable
    /// ceiling — doesn't apply. Distinct from the static, hardware-only
    /// `effectiveMaximum(supportsBoost:)` the popover's slider/icon still use
    /// — that track intentionally keeps its fixed 0...200 domain regardless
    /// of a personal ceiling; only how far a set percentage is allowed to
    /// travel changes here.
    private var currentEffectiveMaximum: Double {
        supportsBoost ? boostCeiling : Self.nominalCeilingPercentage
    }

    /// Rebuilds `currentState` from the live percentage plus whichever
    /// stored properties haven't changed, defaulting every other field to
    /// its current `currentState` value or the controller's own stored copy.
    private func updatedState(percentage: Double, launchAtLoginEnabled: Bool? = nil, boostBlockedByOtherApp: Bool? = nil) -> State {
        Self.state(
            for: percentage,
            supportsBoost: supportsBoost,
            launchAtLoginEnabled: launchAtLoginEnabled ?? currentState.launchAtLoginEnabled,
            launchAtLoginNeedsApproval: currentState.launchAtLoginNeedsApproval,
            launchAtLoginStatusMessage: currentState.launchAtLoginStatusMessage,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut,
            boostBlockedByOtherApp: boostBlockedByOtherApp ?? currentState.boostBlockedByOtherApp
        )
    }

    private func schedulePersist(_ percentage: Double) {
        pendingPersistWorkItem?.cancel()

        let workItem = DispatchWorkItem { [persistence = self.persistence] in
            persistence.save(percentage: percentage)
        }
        pendingPersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistenceDebounceInterval, execute: workItem)
    }

    /// On a non-XDR Mac, Nominal Brightness (0...100) is the entire reachable
    /// range — Boost doesn't exist there, so both the clamp ceiling and the
    /// icon's "full" mark move to 100 rather than staying pinned at 200.
    /// Not `private` — the popover's quick-set row and custom slider need
    /// the same rule to compute "Max boi" and the track's fill fraction, and
    /// having three independent copies of this ternary was a real
    /// duplication risk once the Boost Ceiling became configurable.
    /// `nonisolated`: called from SwiftUI view code that isn't itself
    /// main-actor-isolated.
    nonisolated static func effectiveMaximum(supportsBoost: Bool) -> Double {
        supportsBoost ? maximumPercentage : nominalCeilingPercentage
    }

    private static func clamp(_ percentage: Double, to effectiveMaximum: Double) -> Double {
        min(max(percentage, minimumPercentage), effectiveMaximum)
    }

    /// Rounds to the nearest multiple of `percentageGranularity`, ties
    /// breaking down (e.g. 137.5 -> 135, not 140) — every slider drag, key
    /// press, and restored-from-persistence value goes through this so the
    /// physical keys and the slider always land on the same grid.
    private static func roundToGranularity(_ percentage: Double) -> Double {
        let steps = ((percentage / percentageGranularity) - 0.5).rounded(.up)
        return steps * percentageGranularity
    }

    private static func resolvedPercentage(_ percentage: Double, effectiveMaximum: Double) -> Double {
        roundToGranularity(clamp(percentage, to: effectiveMaximum))
    }

    private static func clampedBoostCeiling(_ percentage: Double) -> Double {
        min(max(percentage, nominalCeilingPercentage), maximumPercentage)
    }

    private static func state(
        for percentage: Double,
        supportsBoost: Bool,
        launchAtLoginEnabled: Bool,
        launchAtLoginNeedsApproval: Bool,
        launchAtLoginStatusMessage: String?,
        boostCeiling: Double,
        keyRemapEnabled: Bool,
        keyRemapShortcut: KeyRemapShortcut,
        boostBlockedByOtherApp: Bool
    ) -> State {
        State(
            percentage: percentage,
            isBoosted: percentage > nominalCeilingPercentage,
            iconFillFraction: percentage / effectiveMaximum(supportsBoost: supportsBoost),
            supportsBoost: supportsBoost,
            launchAtLoginEnabled: launchAtLoginEnabled,
            launchAtLoginNeedsApproval: launchAtLoginNeedsApproval,
            launchAtLoginStatusMessage: launchAtLoginStatusMessage,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut,
            boostBlockedByOtherApp: boostBlockedByOtherApp
        )
    }
}
