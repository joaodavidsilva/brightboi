import Foundation

/// Real `ThermalStateProviding`, wrapping the public `ProcessInfo` API
/// directly — no private/undocumented calls needed here, unlike
/// `RealAutoBrightnessToggle`. `@MainActor` per the protocol — its observer
/// setup/teardown is only ever driven from `BrightnessController.start()`.
@MainActor
final class RealThermalStateProvider: ThermalStateProviding {
    private var onChange: (() -> Void)?
    private var observer: NSObjectProtocol?

    func currentThermalState() -> ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    /// `ProcessInfo.thermalStateDidChangeNotification` is posted on an
    /// arbitrary thread, so registering with `queue: .main` is what makes
    /// hopping to the main actor below safe. `onChange` is stashed on
    /// `self` rather than captured directly, since capturing it straight
    /// into `NotificationCenter`'s `@Sendable` observer closure isn't
    /// allowed — only the class reference itself crosses that boundary.
    func startObserving(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onChange?()
            }
        }
    }

    isolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
