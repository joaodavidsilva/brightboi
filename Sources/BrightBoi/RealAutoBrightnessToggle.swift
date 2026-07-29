import Foundation

/// Real `AutoBrightnessToggling`, built from ticket 06's spike
/// (`docs/brightness-api-research.md`): `CoreBrightness.framework`'s
/// `CBALCSetDisplayAutoBrightnessEnabled` writes the exact preference
/// (`com.apple.CoreBrightness`'s `"Automatic Display Enabled"`) that macOS's
/// own "Automatically adjust brightness" checkbox reads and writes, and the
/// live `corebrightnessd` daemon confirmed processing the call (not just an
/// inert local write) — see the spike's `log show` evidence.
final class RealAutoBrightnessToggle: AutoBrightnessToggling {
    private typealias SetDisplayAutoBrightnessFunc = @convention(c) (Bool) -> Void

    private let setDisplayAutoBrightnessEnabled: SetDisplayAutoBrightnessFunc?

    init() {
        self.setDisplayAutoBrightnessEnabled = Self.loadSetDisplayAutoBrightnessSymbol()
    }

    func disableAutoBrightness() {
        setDisplayAutoBrightnessEnabled?(false)
    }

    /// `CoreBrightness.framework` is private and undocumented (see
    /// ADR-0001) — if it can't be loaded, this becomes a silent no-op
    /// rather than crashing the menu bar app.
    private static func loadSetDisplayAutoBrightnessSymbol() -> SetDisplayAutoBrightnessFunc? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_NOW
        ) else {
            FileHandle.standardError.write(Data("BrightBoi: could not dlopen CoreBrightness.framework\n".utf8))
            return nil
        }
        guard let symbol = dlsym(handle, "CBALCSetDisplayAutoBrightnessEnabled") else {
            FileHandle.standardError.write(Data("BrightBoi: could not dlsym CBALCSetDisplayAutoBrightnessEnabled\n".utf8))
            return nil
        }
        return unsafeBitCast(symbol, to: SetDisplayAutoBrightnessFunc.self)
    }
}
