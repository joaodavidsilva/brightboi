import IOKit.ps

/// Real `PowerSourceProviding`, backed by the public IOKit power-source APIs
/// (no private frameworks needed here, unlike `RealAutoBrightnessToggle`).
final class RealPowerSourceProvider: PowerSourceProviding {
    func isOnBatteryPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        // A MacBook has exactly one power source (its internal battery), so
        // the first one with a readable state is the answer — there's no
        // multi-battery case on this app's target hardware to reconcile.
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            return state == kIOPSBatteryPowerValue
        }
        return false
    }
}
