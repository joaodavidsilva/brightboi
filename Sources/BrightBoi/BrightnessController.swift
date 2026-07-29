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

    struct State: Equatable {
        var percentage: Double
        var isBoosted: Bool
        var iconFillFraction: Double
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
    private var pendingPersistWorkItem: DispatchWorkItem?

    init(
        displayBrightness: DisplayBrightnessProviding,
        autoBrightnessToggle: AutoBrightnessToggling,
        loginItemService: LoginItemRegistering,
        persistence: BrightnessPersisting,
        keyTap: KeyTapControlling,
        keyStepPercentage: Double = 6.25,
        persistenceDebounceInterval: TimeInterval = 0.3
    ) {
        self.displayBrightness = displayBrightness
        self.autoBrightnessToggle = autoBrightnessToggle
        self.loginItemService = loginItemService
        self.persistence = persistence
        self.keyTap = keyTap
        self.keyStepPercentage = keyStepPercentage
        self.persistenceDebounceInterval = persistenceDebounceInterval

        let restoredPercentage = Self.clamp(persistence.loadPercentage() ?? Self.minimumPercentage)
        self.currentState = Self.state(for: restoredPercentage)
        self.displayBrightness.apply(percentage: restoredPercentage)

        // Session-start-only effects: fired once here, never again per session.
        self.autoBrightnessToggle.disableAutoBrightness()
        self.loginItemService.registerForLaunchAtLogin()
        self.keyTap.startIntercepting()
    }

    func setPercentage(_ percentage: Double) {
        let clamped = Self.clamp(percentage)
        currentState = Self.state(for: clamped)
        displayBrightness.apply(percentage: clamped)
        schedulePersist(clamped)
    }

    func handleKeyPress(_ press: KeyPress) {
        let delta = press == .raise ? keyStepPercentage : -keyStepPercentage
        setPercentage(currentState.percentage + delta)
    }

    private func schedulePersist(_ percentage: Double) {
        pendingPersistWorkItem?.cancel()

        let workItem = DispatchWorkItem { [persistence = self.persistence] in
            persistence.save(percentage: percentage)
        }
        pendingPersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistenceDebounceInterval, execute: workItem)
    }

    private static func clamp(_ percentage: Double) -> Double {
        min(max(percentage, minimumPercentage), maximumPercentage)
    }

    private static func state(for percentage: Double) -> State {
        State(
            percentage: percentage,
            isBoosted: percentage > nominalCeilingPercentage,
            iconFillFraction: percentage / maximumPercentage
        )
    }
}
