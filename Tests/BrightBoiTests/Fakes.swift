@testable import BrightBoi

/// Fakes for `BrightnessController`'s system-facing protocols. Used
/// exclusively in tests — no production code depends on these.

final class FakeDisplayBrightnessProvider: DisplayBrightnessProviding {
    private(set) var appliedPercentages: [Double] = []

    func apply(percentage: Double) {
        appliedPercentages.append(percentage)
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

    func registerForLaunchAtLogin() {
        registerCallCount += 1
    }
}

final class FakeBrightnessPersistence: BrightnessPersisting {
    private(set) var savedPercentages: [Double] = []
    var storedPercentage: Double?

    func save(percentage: Double) {
        savedPercentages.append(percentage)
        storedPercentage = percentage
    }

    func loadPercentage() -> Double? {
        storedPercentage
    }
}

final class FakeKeyTap: KeyTapControlling {
    private(set) var startCallCount = 0

    func startIntercepting() {
        startCallCount += 1
    }
}
