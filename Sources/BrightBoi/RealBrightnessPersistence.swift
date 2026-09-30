import Foundation
import os

/// Real `BrightnessPersisting`, backed by `UserDefaults.standard`. Plain
/// `UserDefaults` already durably survives app relaunch, sleep/wake, and
/// reboot (it's written through to disk, not just kept in memory) — no
/// custom durability mechanism needed beyond reading/writing the one key.
final class RealBrightnessPersistence: BrightnessPersisting {
    private static let percentageKey = "com.ptlghost.BrightBoi.percentage"
    static let launchAtLoginEnabledKey = "com.ptlghost.BrightBoi.launchAtLoginEnabled"
    private static let lastRegisteredLoginItemPathKey = "com.ptlghost.BrightBoi.lastRegisteredLoginItemPath"
    private static let boostCeilingKey = "com.ptlghost.BrightBoi.boostCeiling"
    private static let keyRemapShortcutKey = "com.ptlghost.BrightBoi.keyRemapShortcut"
    // Only ever written by `loadKeyRemapShortcut()` right before it reports a
    // decode failure, and only if empty — preserves the original bytes
    // through a later single-row Settings edit, which otherwise overwrites
    // the unreadable record for good (the other half of that edit is built
    // from the in-memory fallback, not from this key).
    private static let keyRemapShortcutUnreadableBackupKey = "com.ptlghost.BrightBoi.keyRemapShortcut.unreadable"
    private static let keyRemapEnabledKey = "com.ptlghost.BrightBoi.keyRemapEnabled"
    private static let hasCompletedOnboardingKey = "com.ptlghost.BrightBoi.hasCompletedOnboarding"
    private static let firstLaunchDateKey = "com.ptlghost.BrightBoi.firstLaunchDate"
    private static let lastDonationPromptDateKey = "com.ptlghost.BrightBoi.lastDonationPromptDate"
    private static let autoBrightnessWasEnabledOriginallyKey = "com.ptlghost.BrightBoi.autoBrightnessWasEnabledOriginally"
    private static let autoBrightnessTakeoverEnabledKey = "com.ptlghost.BrightBoi.autoBrightnessTakeoverEnabled"

    private static let logger = Logger(subsystem: "com.ptlghost.BrightBoi", category: "persistence")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(percentage: Double) {
        defaults.set(percentage, forKey: Self.percentageKey)
    }

    /// `nil` for a missing key, a wrong-typed stored value (e.g. a String
    /// left by hand-editing), or a non-finite one (NaN/infinity survives a
    /// plist round trip but must never reach the display or the UI) —
    /// `BrightnessController` treats all three exactly like a fresh install:
    /// adopt the display's own current level rather than jumping to a fixed
    /// default. `UserDefaults.double(forKey:)` would report `0` for a
    /// missing key, indistinguishable from a genuinely-saved `0%`; reading
    /// via `object(forKey:)` first tells the two apart.
    func loadPercentage() -> Double? {
        guard let value = defaults.object(forKey: Self.percentageKey) as? Double, value.isFinite else { return nil }
        return value
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

    func save(lastRegisteredLoginItemPath: String) {
        defaults.set(lastRegisteredLoginItemPath, forKey: Self.lastRegisteredLoginItemPathKey)
    }

    /// `nil` until the first successful `register()` — `BrightnessController`
    /// treats that as "never registered before", as opposed to "registered,
    /// then the user removed it" once a real status of `.notRegistered`/
    /// `.notFound` comes back.
    func loadLastRegisteredLoginItemPath() -> String? {
        defaults.string(forKey: Self.lastRegisteredLoginItemPathKey)
    }

    func save(boostCeiling: Double) {
        defaults.set(boostCeiling, forKey: Self.boostCeilingKey)
    }

    /// `nil` on a fresh install, a non-finite stored value, or a wrong type —
    /// `BrightnessController` treats that as defaulting to
    /// `maximumPercentage`, unlike `loadPercentage`'s safety-motivated
    /// fallback: an unset Boost Ceiling isn't a "could blank the screen"
    /// concern, just an ordinary preference default.
    func loadBoostCeiling() -> Double? {
        guard let value = defaults.object(forKey: Self.boostCeilingKey) as? Double, value.isFinite else { return nil }
        return value
    }

    func save(keyRemapShortcut: KeyRemapShortcut) {
        guard let data = try? JSONEncoder().encode(keyRemapShortcut) else { return }
        defaults.set(data, forKey: Self.keyRemapShortcutKey)
    }

    /// `nil` on a fresh install, or when the stored blob can't be decoded —
    /// the latter is logged rather than silently swallowed, since a future
    /// change to `KeyCombo`/`KeyRemapShortcut` could otherwise reset an
    /// upgrader's custom shortcut to F1/F2 without a trace. Never rewrites
    /// the unreadable record itself (only reads happen here); a backup copy
    /// is kept under a separate key so a later single-row Settings edit —
    /// which saves a shortcut built from the in-memory F1/F2 fallback —
    /// can't destroy the only copy of what was actually on disk.
    func loadKeyRemapShortcut() -> KeyRemapShortcut? {
        guard let data = defaults.data(forKey: Self.keyRemapShortcutKey) else { return nil }
        do {
            return try JSONDecoder().decode(KeyRemapShortcut.self, from: data)
        } catch {
            Self.logger.error("Stored Key Remap shortcut unreadable, using F1/F2: \(String(describing: error), privacy: .public)")
            if defaults.data(forKey: Self.keyRemapShortcutUnreadableBackupKey) == nil {
                defaults.set(data, forKey: Self.keyRemapShortcutUnreadableBackupKey)
            }
            return nil
        }
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

    func save(firstLaunchDate: Date) {
        defaults.set(firstLaunchDate, forKey: Self.firstLaunchDateKey)
    }

    /// `nil` until the first launch records it, or for a wrong-typed value.
    func loadFirstLaunchDate() -> Date? {
        defaults.object(forKey: Self.firstLaunchDateKey) as? Date
    }

    func save(lastDonationPromptDate: Date) {
        defaults.set(lastDonationPromptDate, forKey: Self.lastDonationPromptDateKey)
    }

    /// `nil` when the window has never appeared by itself, or for a
    /// wrong-typed value.
    func loadLastDonationPromptDate() -> Date? {
        defaults.object(forKey: Self.lastDonationPromptDateKey) as? Date
    }

    func save(autoBrightnessWasEnabledOriginally: Bool) {
        defaults.set(autoBrightnessWasEnabledOriginally, forKey: Self.autoBrightnessWasEnabledOriginallyKey)
    }

    func loadAutoBrightnessWasEnabledOriginally() -> Bool? {
        defaults.object(forKey: Self.autoBrightnessWasEnabledOriginallyKey) as? Bool
    }

    func clearAutoBrightnessWasEnabledOriginally() {
        defaults.removeObject(forKey: Self.autoBrightnessWasEnabledOriginallyKey)
    }

    func save(autoBrightnessTakeoverEnabled: Bool) {
        defaults.set(autoBrightnessTakeoverEnabled, forKey: Self.autoBrightnessTakeoverEnabledKey)
    }

    /// `nil` on a fresh install — `BrightnessController` treats that as
    /// `true`, matching every existing user's unconditional takeover.
    func loadAutoBrightnessTakeoverEnabled() -> Bool? {
        defaults.object(forKey: Self.autoBrightnessTakeoverEnabledKey) as? Bool
    }
}
