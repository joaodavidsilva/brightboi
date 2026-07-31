import Foundation

/// Real `ThermalStateProviding`, wrapping the public `ProcessInfo` API
/// directly — no private/undocumented calls needed here, unlike
/// `RealAutoBrightnessToggle`.
final class RealThermalStateProvider: ThermalStateProviding {
    func currentThermalState() -> ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}
