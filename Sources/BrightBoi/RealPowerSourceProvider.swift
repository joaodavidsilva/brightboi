import Foundation
import IOKit.ps

/// Real `PowerSourceProviding`, backed by the public IOKit power-source APIs
/// and `ProcessInfo` (no private frameworks needed here, unlike
/// `RealAutoBrightnessToggle`). `@MainActor` per the protocol — its observer
/// setup/teardown is only ever driven from `BrightnessController.start()`.
@MainActor
final class RealPowerSourceProvider: PowerSourceProviding {
    private var onChange: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var lowPowerModeObserver: NSObjectProtocol?

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

    func isLowPowerModeEnabled() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// One callback for two independent triggers: an IOKit power-source
    /// change (plug/unplug, a charge-percentage tick — `IOPSNotificationCreateRunLoopSource`)
    /// and Low Power Mode flipping on its own, which `pmset` allows on
    /// either power source (`NSProcessInfoPowerStateDidChange`). The caller
    /// re-reads whichever value it cares about and decides whether anything
    /// it renders actually needs to change — this only signals "go
    /// re-check".
    func startObserving(_ onChange: @escaping () -> Void) {
        self.onChange = onChange

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let provider = Unmanaged<RealPowerSourceProvider>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                provider.onChange?()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }

        lowPowerModeObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onChange?()
            }
        }
    }

    isolated deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let lowPowerModeObserver {
            NotificationCenter.default.removeObserver(lowPowerModeObserver)
        }
    }
}
