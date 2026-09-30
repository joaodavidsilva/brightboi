import Foundation

/// Real `AutoBrightnessToggling`, built from the research in
/// `docs/brightness-api-research.md`: `CoreBrightness.framework`'s
/// `CBALCSetDisplayAutoBrightnessEnabled` writes the exact preference
/// (`com.apple.CoreBrightness`'s `"Automatic Display Enabled"`) that macOS's
/// own "Automatically adjust brightness" checkbox reads and writes, and the
/// live `corebrightnessd` daemon was seen processing the call (not just an
/// inert local write).
final class RealAutoBrightnessToggle: AutoBrightnessToggling {
    private typealias SetDisplayAutoBrightnessFunc = @convention(c) (Bool) -> Void

    // Plain immutable string constants, never mutated after this point —
    // `nonisolated(unsafe)` is safe here because `CFString` itself just
    // isn't (and can't be made) `Sendable`, not because these are shared
    // mutable state.
    nonisolated(unsafe) private static let coreBrightnessDomain = "com.apple.CoreBrightness" as CFString
    nonisolated(unsafe) private static let autoBrightnessKey = "Automatic Display Enabled" as CFString

    private let setDisplayAutoBrightnessEnabled: SetDisplayAutoBrightnessFunc?

    init() {
        self.setDisplayAutoBrightnessEnabled = Self.loadSetDisplayAutoBrightnessSymbol()
    }

    func disableAutoBrightness() {
        setDisplayAutoBrightnessEnabled?(false)
    }

    func enableAutoBrightness() {
        setDisplayAutoBrightnessEnabled?(true)
    }

    /// Reads the public preference directly (`CFPreferencesCopyAppValue`)
    /// rather than the private `CBALCGetDisplayAutoBrightnessEnabled` —
    /// research recorded that getter crashing with `SIGSEGV` on back-to-back
    /// calls. `CFPreferencesAppSynchronize` first so a cached value from
    /// before `corebrightnessd` last wrote it isn't returned.
    func isAutoBrightnessEnabled() -> Bool? {
        guard setDisplayAutoBrightnessEnabled != nil else { return nil }
        CFPreferencesAppSynchronize(Self.coreBrightnessDomain)
        guard let number = CFPreferencesCopyAppValue(Self.autoBrightnessKey, Self.coreBrightnessDomain) as? NSNumber else {
            // Absent key: the checkbox has never been touched on this Mac,
            // which means macOS's own default — enabled — is in effect.
            return true
        }
        return number.boolValue
    }

    /// `CoreBrightness.framework` is private and undocumented — if it can't
    /// be loaded, the failure is logged and the toggle does nothing rather
    /// than crashing the menu bar app; `isAutoBrightnessEnabled()` then
    /// reports `nil`, which the controller surfaces as unavailable.
    private static func loadSetDisplayAutoBrightnessSymbol() -> SetDisplayAutoBrightnessFunc? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_NOW
        ) else {
            Log.autoBrightness.error("Could not load CoreBrightness.framework")
            return nil
        }
        guard let symbol = dlsym(handle, "CBALCSetDisplayAutoBrightnessEnabled") else {
            Log.autoBrightness.error("Could not find CBALCSetDisplayAutoBrightnessEnabled in CoreBrightness.framework")
            return nil
        }
        return unsafeBitCast(symbol, to: SetDisplayAutoBrightnessFunc.self)
    }
}
