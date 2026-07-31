@testable import BrightBoi

/// Fakes for `BrightnessController`'s system-facing protocols. Used
/// exclusively in tests — no production code depends on these.

final class FakeDisplayBrightnessProvider: DisplayBrightnessProviding {
    private(set) var appliedPercentages: [Double] = []
    var stubbedSupportsExtendedBrightness = true

    func apply(percentage: Double) {
        appliedPercentages.append(percentage)
    }

    func supportsExtendedBrightness() -> Bool {
        stubbedSupportsExtendedBrightness
    }
}

final class FakeAutoBrightnessToggle: AutoBrightnessToggling {
    private(set) var disableCallCount = 0

    func disableAutoBrightness() {
        disableCallCount += 1
    }
}

final class FakeLoginItemService: LoginItemRegistering {
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    func registerForLaunchAtLogin() {
        registerCallCount += 1
    }

    func unregisterFromLaunchAtLogin() {
        unregisterCallCount += 1
    }
}

final class FakeBrightnessPersistence: BrightnessPersisting {
    private(set) var savedPercentages: [Double] = []
    var storedPercentage: Double?
    var storedLaunchAtLoginEnabled: Bool?

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
}

final class FakeKeyTap: KeyTapControlling {
    private(set) var startCallCount = 0
    private var onKeyPress: ((BrightnessController.KeyPress) -> Void)?

    func startIntercepting(onKeyPress: @escaping (BrightnessController.KeyPress) -> Void) {
        startCallCount += 1
        self.onKeyPress = onKeyPress
    }

    /// Simulates a real key tap reporting a press, exercising the same
    /// callback path `RealKeyTap` drives in production.
    func simulateKeyPress(_ press: BrightnessController.KeyPress) {
        onKeyPress?(press)
    }
}
