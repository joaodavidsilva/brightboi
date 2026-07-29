import Foundation

/// Drives the built-in display's actual brightness. Ticket 04/05 supply the
/// real implementation (private/EDR techniques per `docs/brightness-api-research.md`);
/// this ticket only defines the seam.
protocol DisplayBrightnessProviding {
    func apply(percentage: Double)
}

/// Disables macOS's native ambient-light-sensor-driven auto-brightness.
/// Ticket 06 supplies the real implementation.
protocol AutoBrightnessToggling {
    func disableAutoBrightness()
}

/// Registers BrightBoi as a login item. Ticket 08 supplies the real
/// `SMAppService`-backed implementation.
protocol LoginItemRegistering {
    func registerForLaunchAtLogin()
}

/// Persists the chosen brightness percentage across relaunch/reboot. Ticket
/// 08 supplies the real `UserDefaults`-backed implementation.
protocol BrightnessPersisting {
    func save(percentage: Double)
    func loadPercentage() -> Double?
}

/// Starts the system-wide F1/F2 key tap. Ticket 07 supplies the real
/// `CGEventTap`-backed implementation.
protocol KeyTapControlling {
    func startIntercepting()
}
