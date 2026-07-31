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
    }

    enum KeyPress {
        case raise
        case lower
    }

    private(set) var currentState: State

    private let displayBrightness: DisplayBrightnessProviding
    private let autoBrightnessToggle: AutoBrightnessToggling
    private let loginItemService: LoginItemRegistering
    private let persistence: BrightnessPersisting
    private let keyTap: KeyTapControlling

    private let keyStepPercentage: Double
    private let persistenceDebounceInterval: TimeInterval
    private let supportsBoost: Bool
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

        let effectiveMaximum = Self.effectiveMaximum(supportsBoost: supportsBoost)
        let restoredPercentage = Self.resolvedPercentage(persistence.loadPercentage() ?? Self.minimumPercentage, effectiveMaximum: effectiveMaximum)
        // `nil` (fresh install) defaults to `true`, matching the app's
        // previous unconditional registration behavior for upgrading users.
        let launchAtLoginEnabled = persistence.loadLaunchAtLoginEnabled() ?? true
        self.currentState = Self.state(for: restoredPercentage, supportsBoost: supportsBoost, launchAtLoginEnabled: launchAtLoginEnabled)
        self.displayBrightness.apply(percentage: restoredPercentage)

        // Session-start-only effects: fired once here, never again per session.
        self.autoBrightnessToggle.disableAutoBrightness()
        if launchAtLoginEnabled {
            self.loginItemService.registerForLaunchAtLogin()
        }
        self.keyTap.startIntercepting { [weak self] press in
            self?.handleKeyPress(press)
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
        let resolved = Self.resolvedPercentage(percentage, effectiveMaximum: Self.effectiveMaximum(supportsBoost: supportsBoost))
        currentState = Self.state(for: resolved, supportsBoost: supportsBoost, launchAtLoginEnabled: currentState.launchAtLoginEnabled)
        displayBrightness.apply(percentage: resolved)
        schedulePersist(resolved)
    }

    func handleKeyPress(_ press: KeyPress) {
        let delta = press == .raise ? keyStepPercentage : -keyStepPercentage
        setPercentage(currentState.percentage + delta)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        currentState = Self.state(for: currentState.percentage, supportsBoost: supportsBoost, launchAtLoginEnabled: enabled)
        persistence.save(launchAtLoginEnabled: enabled)
        if enabled {
            loginItemService.registerForLaunchAtLogin()
        } else {
            loginItemService.unregisterFromLaunchAtLogin()
        }
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
    private static func effectiveMaximum(supportsBoost: Bool) -> Double {
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

    private static func state(for percentage: Double, supportsBoost: Bool, launchAtLoginEnabled: Bool) -> State {
        State(
            percentage: percentage,
            isBoosted: percentage > nominalCeilingPercentage,
            iconFillFraction: percentage / effectiveMaximum(supportsBoost: supportsBoost),
            supportsBoost: supportsBoost,
            launchAtLoginEnabled: launchAtLoginEnabled
        )
    }
}
