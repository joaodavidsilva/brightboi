import AppKit
import Foundation
import Observation

/// The single seam the whole app is built around. Internally depends only on
/// small protocols for every system-facing effect (`DisplayBrightnessProviding`,
/// `AutoBrightnessToggling`, `LoginItemRegistering`, `BrightnessPersisting`,
/// `KeyTapControlling`) — real implementations arrive in later tickets; this
/// ticket establishes the seam and its fully-fake-backed test suite.
///
/// `@Observable` so the menu bar UI (slider, live icon) re-renders as
/// `currentState` changes, without needing a separate published wrapper.
@Observable
final class BrightnessController {
    /// Percentage bounds per the spec: 0–100 is Nominal Brightness,
    /// 100–200 is Extended Brightness / Boost.
    static let minimumPercentage: Double = 0
    static let maximumPercentage: Double = 200
    static let nominalCeilingPercentage: Double = 100
    static let percentageGranularity: Double = 5

    struct State: Equatable {
        var percentage: Double
        var isBoosted: Bool
        var iconFillFraction: Double
        var supportsBoost: Bool
        var launchAtLoginEnabled: Bool
        var boostCeiling: Double
        var keyRemapEnabled: Bool
        var keyRemapShortcut: KeyRemapShortcut

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

    private(set) var currentState: State

    /// Notified after every recognized key press is applied to `currentState`
    /// — including a press that clamps at the 0%/200% ends and so leaves the
    /// percentage unchanged. The HUD (ticket 03) hooks in here rather than
    /// diffing `currentState`, since it must show/reset its dismiss timer on
    /// the press itself, not on a percentage value that happens to differ.
    var onKeyPress: ((KeyPress) -> Void)?

    private let displayBrightness: DisplayBrightnessProviding
    private let autoBrightnessToggle: AutoBrightnessToggling
    private let loginItemService: LoginItemRegistering
    private let persistence: BrightnessPersisting
    private let keyTap: KeyTapControlling

    private let keyStepPercentage: Double
    private let persistenceDebounceInterval: TimeInterval
    private let supportsBoost: Bool
    private var boostCeiling: Double
    private var keyRemapEnabled: Bool
    private var keyRemapShortcut: KeyRemapShortcut
    private var pendingPersistWorkItem: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    init(
        displayBrightness: DisplayBrightnessProviding,
        autoBrightnessToggle: AutoBrightnessToggling,
        loginItemService: LoginItemRegistering,
        persistence: BrightnessPersisting,
        keyTap: KeyTapControlling,
        keyStepPercentage: Double = percentageGranularity,
        persistenceDebounceInterval: TimeInterval = 0.3
    ) {
        self.displayBrightness = displayBrightness
        self.autoBrightnessToggle = autoBrightnessToggle
        self.loginItemService = loginItemService
        self.persistence = persistence
        self.keyTap = keyTap
        self.keyStepPercentage = keyStepPercentage
        self.persistenceDebounceInterval = persistenceDebounceInterval

        // Session-start-only check, same one-shot pattern as the
        // Auto-Brightness Takeover call below — Boost availability can't
        // change mid-session, since it depends on the built-in display's
        // fixed physical headroom.
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
        let launchAtLoginEnabled = persistence.loadLaunchAtLoginEnabled() ?? true
        self.currentState = Self.state(
            for: restoredPercentage,
            supportsBoost: supportsBoost,
            launchAtLoginEnabled: launchAtLoginEnabled,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut
        )
        self.displayBrightness.apply(percentage: restoredPercentage)

        // Session-start-only effects: fired once here, never again per session.
        self.autoBrightnessToggle.disableAutoBrightness()
        if launchAtLoginEnabled {
            self.loginItemService.registerForLaunchAtLogin()
        }
        if keyRemapEnabled {
            self.startKeyTap(remap: keyRemapShortcut)
        }

        // The debounce window (default 0.3s) would otherwise drop the final
        // percentage if the user quits right after their last slider/key
        // move — flush any pending save synchronously before the app exits.
        self.terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingPersist()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func setPercentage(_ percentage: Double) {
        let resolved = Self.resolvedPercentage(percentage, effectiveMaximum: currentEffectiveMaximum)
        currentState = updatedState(percentage: resolved)
        displayBrightness.apply(percentage: resolved)
        schedulePersist(resolved)
    }

    func handleKeyPress(_ press: KeyPress) {
        let delta = press == .raise ? keyStepPercentage : -keyStepPercentage
        setPercentage(currentState.percentage + delta)
        onKeyPress?(press)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        currentState = updatedState(percentage: currentState.percentage, launchAtLoginEnabled: enabled)
        persistence.save(launchAtLoginEnabled: enabled)
        if enabled {
            loginItemService.registerForLaunchAtLogin()
        } else {
            loginItemService.unregisterFromLaunchAtLogin()
        }
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

    private func startKeyTap(remap: KeyRemapShortcut) {
        keyTap.start(remap: remap) { [weak self] press in
            self?.handleKeyPress(press)
        }
    }

    /// The ceiling `setPercentage`/key presses actually clamp against: the
    /// user's configured Boost Ceiling on an XDR Mac, or the fixed Nominal
    /// ceiling on a non-XDR Mac where Boost — and therefore a configurable
    /// ceiling — doesn't apply. Distinct from the static, hardware-only
    /// `effectiveMaximum(supportsBoost:)` the popover's slider/icon still use
    /// (ticket 01) — that track intentionally keeps its fixed 0...200 domain
    /// regardless of a personal ceiling; only how far a set percentage is
    /// allowed to travel changes here.
    private var currentEffectiveMaximum: Double {
        supportsBoost ? boostCeiling : Self.nominalCeilingPercentage
    }

    /// Rebuilds `currentState` from the live percentage plus whichever
    /// stored properties haven't changed, defaulting every other field to
    /// its current `currentState` value or the controller's own stored copy.
    private func updatedState(percentage: Double, launchAtLoginEnabled: Bool? = nil) -> State {
        Self.state(
            for: percentage,
            supportsBoost: supportsBoost,
            launchAtLoginEnabled: launchAtLoginEnabled ?? currentState.launchAtLoginEnabled,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut
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

    private func flushPendingPersist() {
        guard let pendingPersistWorkItem else { return }
        pendingPersistWorkItem.cancel()
        persistence.save(percentage: currentState.percentage)
        self.pendingPersistWorkItem = nil
    }

    /// On a non-XDR Mac, Nominal Brightness (0...100) is the entire reachable
    /// range — Boost doesn't exist there, so both the clamp ceiling and the
    /// icon's "full" mark move to 100 rather than staying pinned at 200.
    /// Not `private` — the popover's quick-set row and custom slider (ticket
    /// 01) need the same rule to compute "Max boi" and the track's fill
    /// fraction, and having three independent copies of this ternary was a
    /// real duplication risk once ticket 02 makes the ceiling configurable.
    static func effectiveMaximum(supportsBoost: Bool) -> Double {
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
        boostCeiling: Double,
        keyRemapEnabled: Bool,
        keyRemapShortcut: KeyRemapShortcut
    ) -> State {
        State(
            percentage: percentage,
            isBoosted: percentage > nominalCeilingPercentage,
            iconFillFraction: percentage / effectiveMaximum(supportsBoost: supportsBoost),
            supportsBoost: supportsBoost,
            launchAtLoginEnabled: launchAtLoginEnabled,
            boostCeiling: boostCeiling,
            keyRemapEnabled: keyRemapEnabled,
            keyRemapShortcut: keyRemapShortcut
        )
    }
}
