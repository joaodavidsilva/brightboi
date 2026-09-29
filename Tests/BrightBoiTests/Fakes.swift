import Foundation
@testable import BrightBoi

/// Fakes for `BrightnessController`'s system-facing protocols. Used
/// exclusively in tests — no production code depends on these.

/// Shared, ordered record of calls across two or more fakes — each fake
/// records only its own calls (see `Fixture`'s per-fake call counts), which
/// can't tell two fakes' calls apart in time. Used to assert real
/// interleaving, e.g. "auto-brightness is disabled before the first
/// display apply".
final class CallLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}

@MainActor
final class FakeDisplayBrightnessProvider: DisplayBrightnessProviding {
    private(set) var appliedPercentages: [Double] = []
    private(set) var adoptExternalNominalCallCount = 0
    var stubbedSupportsExtendedBrightness = true
    var stubbedIsBuiltInDisplayAvailable = true
    var onDisplayConfigurationChange: (() -> Void)?
    var stubbedOutcome: BrightnessApplyOutcome = .applied
    /// `nil` (the default) simulates a display that can't be read — the
    /// same as production hitting clamshell mode or a symbol that failed to
    /// load. Tests that care about the read-back path set this explicitly.
    var stubbedCurrentNominalPercentage: Double?
    var callLog: CallLog?

    func apply(percentage: Double) -> BrightnessApplyOutcome {
        appliedPercentages.append(percentage)
        callLog?.record("apply(\(percentage))")
        return stubbedOutcome
    }

    func supportsExtendedBrightness() -> Bool {
        stubbedSupportsExtendedBrightness
    }

    var isBuiltInDisplayAvailable: Bool {
        stubbedIsBuiltInDisplayAvailable
    }

    func currentNominalPercentage() -> Double? {
        stubbedCurrentNominalPercentage
    }

    func adoptExternalNominal() {
        adoptExternalNominalCallCount += 1
    }
}

final class FakeAutoBrightnessToggle: AutoBrightnessToggling {
    private(set) var disableCallCount = 0
    private(set) var enableCallCount = 0
    var stubbedIsAutoBrightnessEnabled: Bool? = true
    var callLog: CallLog?

    func disableAutoBrightness() {
        disableCallCount += 1
        callLog?.record("disableAuto")
    }

    func enableAutoBrightness() {
        enableCallCount += 1
        callLog?.record("enableAuto")
    }

    func isAutoBrightnessEnabled() -> Bool? {
        stubbedIsAutoBrightnessEnabled
    }
}

/// A trivial `Error` for stubbing `register()`/`unregister()` failures —
/// `BrightnessController` only ever reads `localizedDescription` off it.
struct FakeLoginItemError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

final class FakeLoginItemService: LoginItemRegistering {
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    var stubbedStatus: LoginItemStatus = .notRegistered
    var stubbedRegisterError: Error?
    var stubbedUnregisterError: Error?

    var status: LoginItemStatus { stubbedStatus }

    func register() throws {
        registerCallCount += 1
        if let stubbedRegisterError {
            throw stubbedRegisterError
        }
        stubbedStatus = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let stubbedUnregisterError {
            throw stubbedUnregisterError
        }
        stubbedStatus = .notRegistered
    }
}

final class FakeBundleLocationProvider: BundleLocationProviding {
    var bundlePath = "/Applications/BrightBoi.app"
    var isInApplicationsFolder = true
    var isTranslocatedOrReadOnly = false
}

final class FakeBrightnessPersistence: BrightnessPersisting {
    private(set) var savedPercentages: [Double] = []
    var storedPercentage: Double?
    var storedLaunchAtLoginEnabled: Bool?
    var storedBoostCeiling: Double?
    var storedKeyRemapShortcut: KeyRemapShortcut?
    var storedKeyRemapEnabled: Bool?
    var storedHasCompletedOnboarding: Bool?
    private(set) var saveHasCompletedOnboardingCallCount = 0
    var storedLastRegisteredLoginItemPath: String?
    var storedAutoBrightnessWasEnabledOriginally: Bool?
    var storedAutoBrightnessTakeoverEnabled: Bool?

    func save(percentage: Double) {
        savedPercentages.append(percentage)
        storedPercentage = percentage
    }

    func loadPercentage() -> Double? {
        storedPercentage
    }

    func save(launchAtLoginEnabled: Bool) {
        storedLaunchAtLoginEnabled = launchAtLoginEnabled
    }

    func loadLaunchAtLoginEnabled() -> Bool? {
        storedLaunchAtLoginEnabled
    }

    func save(lastRegisteredLoginItemPath: String) {
        storedLastRegisteredLoginItemPath = lastRegisteredLoginItemPath
    }

    func loadLastRegisteredLoginItemPath() -> String? {
        storedLastRegisteredLoginItemPath
    }

    func save(boostCeiling: Double) {
        storedBoostCeiling = boostCeiling
    }

    func loadBoostCeiling() -> Double? {
        storedBoostCeiling
    }

    func save(keyRemapShortcut: KeyRemapShortcut) {
        storedKeyRemapShortcut = keyRemapShortcut
    }

    func loadKeyRemapShortcut() -> KeyRemapShortcut? {
        storedKeyRemapShortcut
    }

    func save(keyRemapEnabled: Bool) {
        storedKeyRemapEnabled = keyRemapEnabled
    }

    func loadKeyRemapEnabled() -> Bool? {
        storedKeyRemapEnabled
    }

    func save(hasCompletedOnboarding: Bool) {
        storedHasCompletedOnboarding = hasCompletedOnboarding
        saveHasCompletedOnboardingCallCount += 1
    }

    func loadHasCompletedOnboarding() -> Bool? {
        storedHasCompletedOnboarding
    }

    func save(autoBrightnessWasEnabledOriginally: Bool) {
        storedAutoBrightnessWasEnabledOriginally = autoBrightnessWasEnabledOriginally
    }

    func loadAutoBrightnessWasEnabledOriginally() -> Bool? {
        storedAutoBrightnessWasEnabledOriginally
    }

    func clearAutoBrightnessWasEnabledOriginally() {
        storedAutoBrightnessWasEnabledOriginally = nil
    }

    func save(autoBrightnessTakeoverEnabled: Bool) {
        storedAutoBrightnessTakeoverEnabled = autoBrightnessTakeoverEnabled
    }

    func loadAutoBrightnessTakeoverEnabled() -> Bool? {
        storedAutoBrightnessTakeoverEnabled
    }
}

@MainActor
final class FakeKeyTap: KeyTapControlling {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var lastStartedRemap: KeyRemapShortcut?
    private var onKeyPress: ((BrightnessController.KeyPress) -> Void)?

    func start(remap: KeyRemapShortcut, onKeyPress: @escaping (BrightnessController.KeyPress) -> Void) {
        startCallCount += 1
        lastStartedRemap = remap
        self.onKeyPress = onKeyPress
    }

    func stop() {
        stopCallCount += 1
        onKeyPress = nil
    }

    /// Simulates a real key tap reporting a press, exercising the same
    /// callback path `RealKeyTap` drives in production.
    func simulateKeyPress(_ press: BrightnessController.KeyPress) {
        onKeyPress?(press)
    }
}

@MainActor
final class FakePowerSourceProvider: PowerSourceProviding {
    var stubbedIsOnBatteryPower = false
    var stubbedIsLowPowerModeEnabled = false
    private var onChange: (() -> Void)?

    func isOnBatteryPower() -> Bool {
        stubbedIsOnBatteryPower
    }

    func isLowPowerModeEnabled() -> Bool {
        stubbedIsLowPowerModeEnabled
    }

    func startObserving(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Simulates an external power-state change (a plug/unplug, a charge
    /// tick, or Low Power Mode flipping) without touching brightness —
    /// mutate the stub(s), then call this to fire the same callback
    /// `RealPowerSourceProvider` would.
    func simulateChange() {
        onChange?()
    }
}

@MainActor
final class FakeThermalStateProvider: ThermalStateProviding {
    var stubbedThermalState: ProcessInfo.ThermalState = .nominal
    private var onChange: (() -> Void)?

    func currentThermalState() -> ProcessInfo.ThermalState {
        stubbedThermalState
    }

    func startObserving(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Simulates an external thermal-state change without touching
    /// brightness — mutate `stubbedThermalState`, then call this to fire
    /// the same callback `RealThermalStateProvider` would.
    func simulateChange() {
        onChange?()
    }
}

final class FakePermissionsChecker: PermissionsChecking {
    var stubbedAccessibilityGranted = true
    var stubbedInputMonitoringGranted = true
    private(set) var accessibilityQueryCount = 0
    private(set) var inputMonitoringQueryCount = 0
    private(set) var requestAccessibilityCallCount = 0
    private(set) var requestInputMonitoringCallCount = 0

    func accessibilityGranted() -> Bool {
        accessibilityQueryCount += 1
        return stubbedAccessibilityGranted
    }

    func inputMonitoringGranted() -> Bool {
        inputMonitoringQueryCount += 1
        return stubbedInputMonitoringGranted
    }

    /// Records the call only — doesn't flip `stubbed...Granted`, since a real
    /// system prompt's outcome is asynchronous and user-driven. Tests that
    /// need a post-request "now granted" status set `stubbed...Granted`
    /// directly before reading it.
    func requestAccessibility() {
        requestAccessibilityCallCount += 1
    }

    func requestInputMonitoring() {
        requestInputMonitoringCallCount += 1
    }
}

/// Stands in for `BrightnessController.PersistScheduler` in tests: captures
/// the debounced-save closure instead of actually waiting out the delay, so
/// a test fires it deterministically (`fire()`) rather than sleeping the
/// test thread and racing the real debounce interval. `schedule` overwrites
/// the previously captured closure on every call, mirroring the coalescing
/// behavior of the real scheduler (only the most recent scheduled save ever
/// runs).
@MainActor
final class ManualPersistScheduler {
    private(set) var lastDelay: TimeInterval?
    private var pendingWork: (() -> Void)?

    func schedule(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        lastDelay = delay
        pendingWork = work
    }

    /// Runs the most recently scheduled closure, as if its delay had just
    /// elapsed. A no-op if nothing is currently scheduled (already fired, or
    /// never scheduled).
    func fire() {
        let work = pendingWork
        pendingWork = nil
        work?()
    }
}
