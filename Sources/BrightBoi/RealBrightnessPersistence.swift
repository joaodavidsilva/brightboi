import Foundation

/// Real `BrightnessPersisting`, backed by `UserDefaults.standard`. Plain
/// `UserDefaults` already durably survives app relaunch, sleep/wake, and
/// reboot (it's written through to disk, not just kept in memory) — no
/// custom durability mechanism needed beyond reading/writing the one key.
final class RealBrightnessPersistence: BrightnessPersisting {
    private static let percentageKey = "com.ptlghost.BrightBoi.percentage"
    private static let launchAtLoginEnabledKey = "com.ptlghost.BrightBoi.launchAtLoginEnabled"
    private static let boostCeilingKey = "com.ptlghost.BrightBoi.boostCeiling"
    private static let keyRemapShortcutKey = "com.ptlghost.BrightBoi.keyRemapShortcut"
    private static let keyRemapEnabledKey = "com.ptlghost.BrightBoi.keyRemapEnabled"
    private static let hasCompletedOnboardingKey = "com.ptlghost.BrightBoi.hasCompletedOnboarding"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(percentage: Double) {
        defaults.set(percentage, forKey: Self.percentageKey)
    }

    /// `UserDefaults.double(forKey:)` returns `0` for a missing key, which
    /// would be indistinguishable from a genuinely-saved `0%` — reading via
    /// `object(forKey:)` first tells the two cases apart. On a genuinely
    /// fresh install (nothing saved yet), reports the old Nominal ceiling
    /// (100%) rather than `BrightnessController`'s own `0%` fallback:
    /// `BrightnessController` applies whatever this returns to the real
    /// display on every launch, so `nil` here would blank the actual screen
    /// on first run before the user has touched anything — the same concern
    /// ticket 04's placeholder was written to avoid, which doesn't go away
    /// now that persistence is real.
    func loadPercentage() -> Double? {
        defaults.object(forKey: Self.percentageKey) as? Double ?? BrightnessController.nominalCeilingPercentage
    }

    func save(launchAtLoginEnabled: Bool) {
        defaults.set(launchAtLoginEnabled, forKey: Self.launchAtLoginEnabledKey)
    }

    /// `nil` on a fresh install (nothing ever persisted) — `BrightnessController`
    /// treats that as defaulting to `true`, matching the app's previous
    /// unconditional registration behavior for upgrading users.
    func loadLaunchAtLoginEnabled() -> Bool? {
        defaults.object(forKey: Self.launchAtLoginEnabledKey) as? Bool
    }

    func save(boostCeiling: Double) {
        defaults.set(boostCeiling, forKey: Self.boostCeilingKey)
    }

    /// `nil` on a fresh install — `BrightnessController` treats that as
    /// defaulting to `maximumPercentage`, unlike `loadPercentage`'s
    /// safety-motivated fallback: an unset Boost Ceiling isn't a "could
    /// blank the screen" concern, just an ordinary preference default.
    func loadBoostCeiling() -> Double? {
        defaults.object(forKey: Self.boostCeilingKey) as? Double
    }

    func save(keyRemapShortcut: KeyRemapShortcut) {
        guard let data = try? JSONEncoder().encode(keyRemapShortcut) else { return }
        defaults.set(data, forKey: Self.keyRemapShortcutKey)
    }

    func loadKeyRemapShortcut() -> KeyRemapShortcut? {
        guard let data = defaults.data(forKey: Self.keyRemapShortcutKey) else { return nil }
        return try? JSONDecoder().decode(KeyRemapShortcut.self, from: data)
    }

    func save(keyRemapEnabled: Bool) {
        defaults.set(keyRemapEnabled, forKey: Self.keyRemapEnabledKey)
    }

    func loadKeyRemapEnabled() -> Bool? {
        defaults.object(forKey: Self.keyRemapEnabledKey) as? Bool
    }

    func save(hasCompletedOnboarding: Bool) {
        defaults.set(hasCompletedOnboarding, forKey: Self.hasCompletedOnboardingKey)
    }

    /// `nil` on a fresh install — `OnboardingModel` treats that as `false`,
    /// the same "never persisted yet" convention every other flag here uses.
    func loadHasCompletedOnboarding() -> Bool? {
        defaults.object(forKey: Self.hasCompletedOnboardingKey) as? Bool
    }
}
