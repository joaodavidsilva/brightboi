import Foundation

/// No-op stand-ins for the system-integration protocols that don't yet have
/// real implementations (ticket 04 only supplies the real
/// `DisplayBrightnessProviding`). `BrightnessController` still requires a
/// concrete value for every protocol, so these let the app actually run
/// end-to-end rather than blocking on tickets 06/07/08. Each is replaced by
/// its ticket's real implementation, not extended in place.

/// Ticket 06 supplies the real implementation.
final class PlaceholderAutoBrightnessToggle: AutoBrightnessToggling {
    func disableAutoBrightness() {}
}

/// Ticket 08 supplies the real `SMAppService`-backed implementation.
final class PlaceholderLoginItemService: LoginItemRegistering {
    func registerForLaunchAtLogin() {}
}

/// Ticket 08 supplies the real `UserDefaults`-backed implementation. This
/// stand-in deliberately doesn't persist anything (in-memory only, lost on
/// relaunch) rather than faking durability it doesn't have. It reports the
/// old Nominal ceiling (100%) rather than `nil`: `BrightnessController` applies
/// whatever this returns to the real display on every launch, and now that
/// ticket 04 wires in a real `DisplayBrightnessProviding`, `nil` (→ 0%) would
/// mean every launch blanks the actual screen before the user touches
/// anything — a real side effect this placeholder shouldn't cause just
/// because durable persistence isn't built yet.
final class PlaceholderBrightnessPersistence: BrightnessPersisting {
    func save(percentage: Double) {}
    func loadPercentage() -> Double? { BrightnessController.nominalCeilingPercentage }
}

/// Ticket 07 supplies the real `CGEventTap`-backed implementation.
final class PlaceholderKeyTap: KeyTapControlling {
    func startIntercepting() {}
}
