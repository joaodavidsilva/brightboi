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

    /// The floor a *persisted* percentage restores to at launch — never
    /// applied to a live drag/key press, which can still reach 0, and never
    /// applied when nothing was persisted (see `PercentageSource` below).
    /// Protects against a saved 0% (the backlight minimum, e.g. after using
    /// it to turn the panel off) silently reapplying a dark screen at every
    /// login; one key press or slider touch recovers from either value, but
    /// 10% never needs recovering from in the first place.
    nonisolated static let minimumRestoredPercentage: Double = 10

    /// How far the display's live Nominal reading may drift from what
    /// BrightBoi last wrote before `syncFromDisplay()` treats it as a real
    /// external change rather than read-back noise or its own rounding.
    /// `DisplayServicesGetBrightness` reports values like `0.8124999`, and
    /// native keys move in 1/16ths (6.25%) — both comfortably clear this;
    /// resolving to the 5% grid can differ from the raw reading by at most
    /// exactly this much (a tie), which must not itself count as a change.
    nonisolated static let displaySyncTolerancePercentage: Double = 2.5

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

        /// `false` while no built-in display is online (lid closed in
        /// clamshell mode): brightness control is unavailable then, and is
        /// never redirected to an external monitor. Defaults to `true` so a
        /// state built for display purposes alone need not name it.
        var builtInDisplayAvailable: Bool = true
        var launchAtLoginEnabled: Bool
        var launchAtLoginNeedsApproval: Bool
        var launchAtLoginStatusMessage: String?
        var boostCeiling: Double
        var keyRemapEnabled: Bool
        var keyRemapShortcut: KeyRemapShortcut
        var autoBrightnessTakeoverEnabled: Bool

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

    /// How the level in `currentState` at the end of `init` was decided —
    /// only relevant to `start()`, which uses it to skip the initial
    /// display write when the value already came from the display itself.
    private enum PercentageSource {
        /// Restored from a previous session.
        case persisted
        /// Nothing was persisted; adopted from the display's own current
        /// reading instead of jumping to a fixed default.
        case adoptedFromDisplay
        /// Nothing was persisted and the display couldn't be read either.
        case fallbackDefault
    }

    /// How `schedulePersist` schedules a debounced save — real code fires it
    /// via `DispatchQueue.main.asyncAfter`, so a physical delay elapses.
    /// Tests inject a synchronous scheduler that just captures the closure
    /// for them to fire explicitly, so a debounce can be exercised
    /// deterministically instead of sleeping the test thread and racing the
    /// wall clock.
    typealias PersistScheduler = (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// The thermal-throttle advisory's content — see ADR-0005: `deliveredPercentage`
    /// is a heuristic estimate (`.serious` → requested − 20, `.critical` →
    /// requested − 40, floored at 100%), never a measurement.
    struct ThermalAdvisory: Equatable {
        var requestedPercentage: Double
        var deliveredPercentage: Double
    }

    private(set) var currentState: State

    /// The three system facts the battery/thermal/Low-Power-Mode advisories
    /// are derived from, kept as their own tracked stored properties (rather
    /// than read fresh from the providers on every access) so `@Observable`
    /// actually notifies SwiftUI when one of them changes on its own —
    /// unplugging the charger, the Mac heating up, Low Power Mode being
    /// toggled — with no brightness change to otherwise trigger a rebuild.
    /// Seeded once at init, kept current afterwards by the observers
    /// `start()` registers.
    private(set) var isOnBatteryPower: Bool
    private(set) var isLowPowerModeEnabled: Bool
    private(set) var thermalState: ProcessInfo.ThermalState

    /// `true` once `start()` has found `AutoBrightnessToggling`'s private
    /// symbol couldn't be loaded — Settings shows a quiet note rather than
    /// silently behaving as if the takeover (and its restore-on-quit) had
    /// happened when neither actually could. Defaults to `false` until
    /// `start()` runs, which is always immediately after construction.
    private(set) var autoBrightnessUnavailable = false

    /// Notified after every recognized key press is applied — including a
    /// press that clamps at the 0%/200% ends and so leaves the percentage
    /// unchanged — with the state as of right after that press. Passing
    /// `State` through the callback (rather than the caller reading
    /// `currentState` back off the controller) means whoever wires this up
    /// doesn't need to capture the controller itself just to read its state.
    @ObservationIgnored
    var onKeyPress: ((KeyPress, State) -> Void)?

    private var displayBrightness: DisplayBrightnessProviding
    private let autoBrightnessToggle: AutoBrightnessToggling
    private let loginItemService: LoginItemRegistering
    private let persistence: BrightnessPersisting
    private let keyTap: KeyTapControlling
    private let powerSource: PowerSourceProviding
    private let thermalStateProvider: ThermalStateProviding
    private let bundleLocation: BundleLocationProviding

    private let keyStepPercentage: Double
    private let persistenceDebounceInterval: TimeInterval
    /// Whether Boost is available right now — can change during a session as
    /// the built-in display comes and goes; see `displayConfigurationDidChange`.
    private var supportsBoost: Bool
    private var builtInDisplayAvailable: Bool
    /// The Boost level (above 100%) the user had before Boost became
    /// unavailable — the built-in display went away, or the session started
    /// without it. Put back when Boost returns, and cleared by any deliberate
    /// change of level. Never persisted: the saved level stays as the user
    /// left it, so a relaunch can still restore it.
    private var boostLevelToRestore: Double?
    private let percentageSource: PercentageSource
    private var boostCeiling: Double
    private var keyRemapEnabled: Bool
    private var keyRemapShortcut: KeyRemapShortcut
    private var autoBrightnessTakeoverEnabled: Bool
    private var hasStarted = false
    private var lastLaunchAtLoginError: String?
    private let schedule: PersistScheduler
    /// The percentage most recently handed to `schedulePersist`, still
    /// unsaved — `nil` once it's been saved (by the scheduled fire or by
    /// `flushPendingPersist`). Read by `flushPendingPersist`; the scheduled
    /// closure itself never reads it back, only `schedulePersist`'s own
    /// capture of the value.
    @ObservationIgnored
    private var pendingPersistPercentage: Double?
    /// Bumped on every `schedulePersist`/`flushPendingPersist` call so a
    /// scheduled closure that fires after a later one superseded it (a
    /// rapid drag scheduled three saves; only the last should ever write)
    /// or after a flush already saved can tell it's stale and no-op,
    /// without needing a cancellable token from `schedule` itself.
    @ObservationIgnored
    private var persistSaveGeneration = 0

    /// Builds the controller and its initial `currentState` from whatever's
    /// already persisted — no side effect touches the display, the login
    /// item list, auto-brightness or the key tap. That happens once in
    /// `start()`, so constructing the controller early (SwiftUI's
    /// `MenuBarExtra`/`Settings` scenes need it at `body` time, before the
    /// app has finished launching) is always safe. Reading the display's own
    /// current brightness here (`DisplayBrightnessProviding.currentNominalPercentage()`)
    /// is likewise a plain read with no side effect — the same category as
    /// `supportsExtendedBrightness()` below, already called from here.
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
        persistenceDebounceInterval: TimeInterval = 0.3,
        schedule: @escaping PersistScheduler = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.displayBrightness = displayBrightness
        self.autoBrightnessToggle = autoBrightnessToggle
        self.loginItemService = loginItemService
        self.persistence = persistence
        self.keyTap = keyTap
        self.powerSource = powerSource
        self.thermalStateProvider = thermalState
        self.bundleLocation = bundleLocation
        self.keyStepPercentage = keyStepPercentage
        self.persistenceDebounceInterval = persistenceDebounceInterval
        self.schedule = schedule

        // Boost needs a built-in display whose panel can grant EDR headroom.
        // That can change mid-session when the display comes or goes (lid,
        // hot-plug), so `displayConfigurationDidChange` re-reads it.
        let supportsBoost = displayBrightness.supportsExtendedBrightness()
        self.supportsBoost = supportsBoost
        let builtInDisplayAvailable = displayBrightness.isBuiltInDisplayAvailable
        self.builtInDisplayAvailable = builtInDisplayAvailable

        // `nil` (fresh install) defaults to `maximumPercentage`, identical
        // to today's fixed 200% ceiling until deliberately lowered. Snapped
        // to the 5% grid so a hand-edited off-grid value can't let
        // `setPercentage` resolve above it.
        let boostCeiling = Self.clampedBoostCeiling(persistence.loadBoostCeiling().flatMap { $0.isFinite ? $0 : nil } ?? Self.maximumPercentage)
        self.boostCeiling = boostCeiling

        let keyRemapEnabled = persistence.loadKeyRemapEnabled() ?? true
        self.keyRemapEnabled = keyRemapEnabled

        let keyRemapShortcut = persistence.loadKeyRemapShortcut() ?? .defaultShortcut
        self.keyRemapShortcut = keyRemapShortcut

        let autoBrightnessTakeoverEnabled = persistence.loadAutoBrightnessTakeoverEnabled() ?? true
        self.autoBrightnessTakeoverEnabled = autoBrightnessTakeoverEnabled

        let boostAwareCeiling = supportsBoost ? boostCeiling : Self.nominalCeilingPercentage

        // Fresh install (nothing persisted): adopt the display's own
        // current level rather than jumping to a fixed default — that's a
        // jarring first impression and, at night, briefly blinding. Falls
        // back to `nominalCeilingPercentage` only when the display can't be
        // read either (e.g. clamshell mode, with no built-in display online).
        // A *persisted* value is
        // floored at `minimumRestoredPercentage`; an adopted display reading
        // is taken exactly as found, including a genuine 0 — the panel's
        // already at that level, so there's nothing to protect against.
        let source: PercentageSource
        let rawPercentage: Double
        if let persisted = persistence.loadPercentage(), persisted.isFinite {
            source = .persisted
            rawPercentage = max(persisted, Self.minimumRestoredPercentage)
        } else if let displayed = displayBrightness.currentNominalPercentage(), displayed.isFinite {
            source = .adoptedFromDisplay
            rawPercentage = displayed
        } else {
            source = .fallbackDefault
            rawPercentage = Self.nominalCeilingPercentage
        }
        self.percentageSource = source

        let restoredPercentage = Self.resolvedPercentage(rawPercentage, effectiveMaximum: boostAwareCeiling)
        if source == .persisted, !supportsBoost {
            // Clamped only because Boost isn't available yet: remember the
            // level so it comes back if Boost does.
            let wanted = Self.resolvedPercentage(rawPercentage, effectiveMaximum: boostCeiling)
            if wanted > Self.nominalCeilingPercentage { self.boostLevelToRestore = wanted }
        }
        // `nil` (fresh install) defaults to `true`, matching the app's
        // previous unconditional registration behavior for upgrading users.
        // `start()` reconciles this against the real login-item status
        // before it ever reaches a view.
        let launchAtLoginEnabled = persistence.loadLaunchAtLoginEnabled() ?? true

        self.isOnBatteryPower = powerSource.isOnBatteryPower()
        self.isLowPowerModeEnabled = powerSource.isLowPowerModeEnabled()
        self.thermalState = thermalState.currentThermalState()

        self.currentState = Self.state(
            for: restoredPercentage,
            supportsBoost: supportsBoost,
            builtInDisplayAvailable: builtInDisplayAvailable,
            launchAtLoginEnabled: launchAtLoginEnabled,
            launchAtLoginNeedsApproval: false,
            launchAtLoginStatusMessage: nil,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut,
            autoBrightnessTakeoverEnabled: autoBrightnessTakeoverEnabled,
            boostBlockedByOtherApp: false
        )
    }

    /// Fires every session-start-only side effect exactly once: records the
    /// real auto-brightness setting (once, ever, per continuous run), takes
    /// over from it, applies the restored percentage to the real display
    /// (skipped when that percentage was adopted from the display itself —
    /// see `PercentageSource`), reconciles/attempts login-item registration,
    /// starts the key tap, and starts observing the power/thermal state the
    /// advisories depend on. Called from
    /// `AppDelegate.applicationDidFinishLaunching`, once `NSApp` has
    /// actually finished launching. Calling it again is a no-op.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // Record before taking over, so the value reflects what the user
        // actually had — guarded by "only if nothing's recorded yet" so a
        // crash between this and `restoreSystemStateOnTermination()` can't
        // have the *next* launch overwrite the true original with the
        // now-disabled value it would read then. The read itself always
        // happens (it's what tells `autoBrightnessUnavailable` apart from a
        // genuinely-enabled system), only the save is guarded.
        let systemAutoBrightnessEnabled = autoBrightnessToggle.isAutoBrightnessEnabled()
        autoBrightnessUnavailable = systemAutoBrightnessEnabled == nil
        if persistence.loadAutoBrightnessWasEnabledOriginally() == nil {
            persistence.save(autoBrightnessWasEnabledOriginally: systemAutoBrightnessEnabled ?? true)
        }
        if autoBrightnessTakeoverEnabled {
            autoBrightnessToggle.disableAutoBrightness()
        }

        if percentageSource == .adoptedFromDisplay {
            // Already the level the display is showing — applying it back
            // would be a no-op at best, and the rounding difference (at
            // most `displaySyncTolerancePercentage`) is invisible. Still
            // schedule a save so the *next* launch has a stored value to
            // restore instead of adopting again.
            schedulePersist(currentState.percentage)
        } else {
            applyToDisplay(percentage: currentState.percentage)
        }

        displayBrightness.onDisplayConfigurationChange = { [weak self] in
            self?.displayConfigurationDidChange()
        }

        syncLaunchAtLoginAtStart()
        if keyRemapEnabled {
            startKeyTap(remap: keyRemapShortcut)
        }

        powerSource.startObserving { [weak self] in self?.refreshObservedPowerState() }
        thermalStateProvider.startObserving { [weak self] in self?.refreshObservedThermalState() }
    }

    func setPercentage(_ percentage: Double) {
        guard percentage.isFinite else { return }
        let resolved = Self.resolvedPercentage(percentage, effectiveMaximum: currentEffectiveMaximum)
        boostLevelToRestore = nil
        applyToDisplay(percentage: resolved)
        schedulePersist(currentState.percentage)
    }

    /// Same resolution as `setPercentage`, but skips the apply and the
    /// persistence reschedule when it resolves to the value already
    /// showing — used only by the slider's drag gesture, which reports
    /// 60-120 pointer events a second and would otherwise re-apply the
    /// unchanged value (while boosted, rebuilding and rewriting the gamma
    /// table) on nearly every one of them. Not used by the quick-set
    /// buttons or a key press: tapping "100%" again, or a key step landing
    /// back where it started, is currently the user's only way to
    /// re-assert BrightBoi's level after something else changed it outside
    /// the app (Control Center, a display reconfiguration, another
    /// utility) — a blanket guard here would turn that into a no-op.
    func setPercentageFromDrag(_ percentage: Double) {
        guard percentage.isFinite else { return }
        let resolved = Self.resolvedPercentage(percentage, effectiveMaximum: currentEffectiveMaximum)
        guard resolved != currentState.percentage else { return }
        boostLevelToRestore = nil
        applyToDisplay(percentage: resolved)
        schedulePersist(currentState.percentage)
    }

    func handleKeyPress(_ press: KeyPress) {
        syncFromDisplay()
        let delta = press == .raise ? keyStepPercentage : -keyStepPercentage
        setPercentage(currentState.percentage + delta)
        onKeyPress?(press, currentState)
    }

    /// Re-reads the display's live Nominal brightness and adopts it when
    /// it's diverged from what BrightBoi itself last put there — a Control
    /// Center drag, a native key press that bypassed Key Remap, or macOS's
    /// own dimming. Compared against the *Nominal* component of the current
    /// state (`min(currentState.percentage, 100)`), since while boosted
    /// BrightBoi always writes 100% (1.0) to Nominal itself — reading 100
    /// back while state is 150 is expected, not an external change, and
    /// must never disengage Boost. Never writes Nominal itself, so an
    /// on-demand call here can't fight a Control Center drag still in
    /// progress; called at the start of `handleKeyPress` (which is about to
    /// write anyway, through its own `setPercentage` call right after) and
    /// from the popover/Settings appearing.
    func syncFromDisplay() {
        guard let reading = displayBrightness.currentNominalPercentage(), reading.isFinite else { return }
        let expectedNominal = min(currentState.percentage, Self.nominalCeilingPercentage)
        guard abs(reading - expectedNominal) > Self.displaySyncTolerancePercentage else { return }

        let adopted = Self.roundToGranularity(Self.clamp(reading, to: Self.nominalCeilingPercentage))
        if currentState.isBoosted {
            displayBrightness.adoptExternalNominal()
        }
        boostLevelToRestore = nil
        currentState = updatedState(percentage: adopted)
        schedulePersist(adopted)
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
            builtInDisplayAvailable: builtInDisplayAvailable,
            launchAtLoginEnabled: status == .enabled || status == .requiresApproval,
            launchAtLoginNeedsApproval: status == .requiresApproval,
            launchAtLoginStatusMessage: message,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut,
            autoBrightnessTakeoverEnabled: autoBrightnessTakeoverEnabled,
            boostBlockedByOtherApp: currentState.boostBlockedByOtherApp
        )
    }

    /// Bounded `[100, 200]` per ADR-0004 — the floor keeps an accidental drag
    /// from blacking out the screen, the ceiling is the hard maximum
    /// ADR-0002 already established. Lowering it below the current live
    /// brightness clamps brightness down immediately, via the `setPercentage`
    /// re-resolve below.
    func setBoostCeiling(_ percentage: Double) {
        guard percentage.isFinite else { return }
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

    /// Drives the Settings toggle "Turn off macOS auto-brightness while
    /// BrightBoi runs" (on by default). Switching it off restores
    /// auto-brightness immediately — but only if the recorded original had
    /// it on, so this can never turn *on* a setting the user had off before
    /// BrightBoi ever ran. Switching it back on disables it again, the same
    /// takeover `start()` performs at launch.
    func setAutoBrightnessTakeoverEnabled(_ enabled: Bool) {
        autoBrightnessTakeoverEnabled = enabled
        persistence.save(autoBrightnessTakeoverEnabled: enabled)
        currentState = updatedState(percentage: currentState.percentage)
        if enabled {
            autoBrightnessToggle.disableAutoBrightness()
        } else if persistence.loadAutoBrightnessWasEnabledOriginally() ?? true {
            autoBrightnessToggle.enableAutoBrightness()
        }
    }

    /// Advisory only — never blocks or clamps the slider. Suppressed
    /// whenever the Low Power Mode advisory is showing, so a user above
    /// 170% on battery with Low Power Mode on sees one banner, not two
    /// near-duplicate power warnings.
    var batteryAdvisoryVisible: Bool {
        currentState.percentage > Self.batteryAdvisoryThresholdPercentage && isOnBatteryPower && !isLowPowerModeAdvisoryVisible
    }

    /// Advisory only — never pauses or blocks Boost. Apple documents Low
    /// Power Mode as reducing screen brightness among its energy-saving
    /// measures; this only surfaces that Boost is working against it, on
    /// either power source, since Low Power Mode can be on while plugged in.
    var isLowPowerModeAdvisoryVisible: Bool {
        currentState.isBoosted && isLowPowerModeEnabled
    }

    /// `nil` unless boosted and the system is under thermal pressure.
    /// Advisory only — never blocks or clamps the slider.
    var thermalAdvisory: ThermalAdvisory? {
        guard currentState.isBoosted else { return nil }
        let requested = currentState.percentage
        switch thermalState {
        case .serious:
            return ThermalAdvisory(
                requestedPercentage: requested,
                deliveredPercentage: max(requested - Self.thermalSeriousDeliveredOffset, Self.nominalCeilingPercentage)
            )
        case .critical:
            return ThermalAdvisory(
                requestedPercentage: requested,
                deliveredPercentage: max(requested - Self.thermalCriticalDeliveredOffset, Self.nominalCeilingPercentage)
            )
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
        guard let pendingPersistPercentage else { return }
        persistence.save(percentage: pendingPersistPercentage)
        self.pendingPersistPercentage = nil
        persistSaveGeneration += 1
    }

    /// Called from `AppDelegate.applicationWillTerminate`, alongside
    /// `flushPendingPersist()`. Restores whatever this session changed that
    /// would otherwise outlive the app: if Boost is engaged, the scaled
    /// gamma table first (so the light sensor's own ramp on next login
    /// doesn't land on top of a still-scaled table), unconditionally — Boost
    /// itself doesn't depend on the takeover setting. The auto-brightness
    /// restore, though, only applies while the takeover is actually
    /// enabled: with it off, BrightBoi never touched macOS's own setting
    /// this session (or the user turned it back off mid-session via the
    /// Settings toggle, which already restored it there and then), so
    /// forcing it back here would silently override a change the user made
    /// on their own — exactly what the toggle being off is supposed to
    /// prevent. Only restores (and clears the recorded original) when the
    /// takeover is enabled, and only re-enables auto-brightness if the
    /// recorded original had it on.
    func restoreSystemStateOnTermination() {
        if currentState.isBoosted {
            displayBrightness.adoptExternalNominal()
        }
        guard autoBrightnessTakeoverEnabled else { return }
        if persistence.loadAutoBrightnessWasEnabledOriginally() ?? true {
            autoBrightnessToggle.enableAutoBrightness()
        }
        persistence.clearAutoBrightnessWasEnabledOriginally()
    }

    /// The built-in display came, went, or changed what it can do (lid
    /// opened or closed, a display plugged in, ...). Re-reads whether Boost
    /// is available and reshapes the state to match, without ever saving the
    /// reshaped level — the persisted level stays as the user left it.
    ///
    /// - Boost went away: the shown level drops to what is reachable (100%),
    ///   and the Boost level is remembered so it comes back with the display.
    /// - Boost is available (again): the remembered level, or the current
    ///   one, is applied to the display.
    /// - The built-in display is back but can't boost: its level is
    ///   re-applied so it matches what the user last chose.
    /// While no built-in display is online nothing is applied at all: there
    /// is nothing to drive, and no other display is ever driven instead.
    private func displayConfigurationDidChange() {
        let nowSupportsBoost = displayBrightness.supportsExtendedBrightness()
        let nowAvailable = displayBrightness.isBuiltInDisplayAvailable
        guard nowSupportsBoost != supportsBoost || nowAvailable != builtInDisplayAvailable else { return }
        supportsBoost = nowSupportsBoost
        builtInDisplayAvailable = nowAvailable

        var target = currentState.percentage
        if !nowSupportsBoost {
            if target > Self.nominalCeilingPercentage {
                boostLevelToRestore = target
                target = Self.nominalCeilingPercentage
            }
        } else if let restore = boostLevelToRestore {
            boostLevelToRestore = nil
            target = restore
        }
        target = Self.resolvedPercentage(target, effectiveMaximum: currentEffectiveMaximum)

        if nowAvailable {
            applyToDisplay(percentage: target)
        } else {
            currentState = updatedState(percentage: target)
        }
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

    /// Re-reads `isOnBatteryPower`/`isLowPowerModeEnabled` and assigns only
    /// what actually changed — the IOKit callback fires on every
    /// power-source event, including a charge-percentage tick, and
    /// `@Observable`'s synthesized setter notifies on every assignment
    /// regardless of whether the value is equal, which would otherwise
    /// re-render the popover every minute on battery.
    private func refreshObservedPowerState() {
        let onBattery = powerSource.isOnBatteryPower()
        if onBattery != isOnBatteryPower {
            isOnBatteryPower = onBattery
        }
        let lowPowerMode = powerSource.isLowPowerModeEnabled()
        if lowPowerMode != isLowPowerModeEnabled {
            isLowPowerModeEnabled = lowPowerMode
        }
    }

    private func refreshObservedThermalState() {
        let state = thermalStateProvider.currentThermalState()
        if state != thermalState {
            thermalState = state
        }
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
            builtInDisplayAvailable: builtInDisplayAvailable,
            launchAtLoginEnabled: launchAtLoginEnabled ?? currentState.launchAtLoginEnabled,
            launchAtLoginNeedsApproval: currentState.launchAtLoginNeedsApproval,
            launchAtLoginStatusMessage: currentState.launchAtLoginStatusMessage,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut,
            autoBrightnessTakeoverEnabled: autoBrightnessTakeoverEnabled,
            boostBlockedByOtherApp: boostBlockedByOtherApp ?? currentState.boostBlockedByOtherApp
        )
    }

    private func schedulePersist(_ percentage: Double) {
        pendingPersistPercentage = percentage
        persistSaveGeneration += 1
        let generation = persistSaveGeneration
        // `@Sendable` (see `PersistScheduler`) since it may cross into
        // `schedule`'s own, non-actor-isolated signature — `assumeIsolated`
        // is safe here the same way it is in `RealPowerSourceProvider`/
        // `RealThermalStateProvider`'s C-callback bridges: every real
        // scheduler (`DispatchQueue.main.asyncAfter`) and every test
        // scheduler always fires this back on the main thread.
        schedule(persistenceDebounceInterval) { [weak self] in
            MainActor.assumeIsolated {
                self?.firePendingPersist(generation: generation, percentage: percentage)
            }
        }
    }

    /// The scheduled closure `schedulePersist` hands to `schedule`. Only
    /// fires the save when `generation` still matches the latest call —
    /// stale otherwise, either because a later `schedulePersist` coalesced
    /// over it (a rapid drag: only the final value should ever save) or
    /// because `flushPendingPersist` already saved it early.
    private func firePendingPersist(generation: Int, percentage: Double) {
        guard generation == persistSaveGeneration else { return }
        persistence.save(percentage: percentage)
        pendingPersistPercentage = nil
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
    /// physical keys and the slider always land on the same grid. The
    /// trailing `+ 0.0` turns a `-0.0` result (e.g. rounding 0 or 2) into
    /// `+0.0` — cosmetically identical (`-0.0 == 0`), but keeps every state,
    /// saved value and display write free of a sign bit nothing downstream
    /// expects.
    private static func roundToGranularity(_ percentage: Double) -> Double {
        let steps = ((percentage / percentageGranularity) - 0.5).rounded(.up)
        return steps * percentageGranularity + 0.0
    }

    private static func resolvedPercentage(_ percentage: Double, effectiveMaximum: Double) -> Double {
        roundToGranularity(clamp(percentage, to: effectiveMaximum))
    }

    /// Snapped to the 5% grid before clamping, so a hand-edited or
    /// programmatically-set off-grid ceiling (e.g. 138) can't let
    /// `setPercentage` resolve a value above it (138 itself would never be
    /// reachable, but 140 — the nearest grid point at or below a rounded
    /// 138 — is the actual ceiling from here on).
    private static func clampedBoostCeiling(_ percentage: Double) -> Double {
        min(max(roundToGranularity(percentage), nominalCeilingPercentage), maximumPercentage)
    }

    private static func state(
        for percentage: Double,
        supportsBoost: Bool,
        builtInDisplayAvailable: Bool,
        launchAtLoginEnabled: Bool,
        launchAtLoginNeedsApproval: Bool,
        launchAtLoginStatusMessage: String?,
        boostCeiling: Double,
        keyRemapEnabled: Bool,
        keyRemapShortcut: KeyRemapShortcut,
        autoBrightnessTakeoverEnabled: Bool,
        boostBlockedByOtherApp: Bool
    ) -> State {
        State(
            percentage: percentage,
            isBoosted: percentage > nominalCeilingPercentage,
            iconFillFraction: percentage / effectiveMaximum(supportsBoost: supportsBoost),
            supportsBoost: supportsBoost,
            builtInDisplayAvailable: builtInDisplayAvailable,
            launchAtLoginEnabled: launchAtLoginEnabled,
            launchAtLoginNeedsApproval: launchAtLoginNeedsApproval,
            launchAtLoginStatusMessage: launchAtLoginStatusMessage,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut,
            autoBrightnessTakeoverEnabled: autoBrightnessTakeoverEnabled,
            boostBlockedByOtherApp: boostBlockedByOtherApp
        )
    }
}
