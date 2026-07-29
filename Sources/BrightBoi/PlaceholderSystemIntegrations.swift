import Foundation

/// No-op stand-in for the one system-integration protocol that doesn't yet
/// have a real implementation (ticket 07 supplies the real
/// `KeyTapControlling`). `BrightnessController` still requires a concrete
/// value for every protocol, so this lets the app actually run end-to-end
/// rather than blocking on ticket 07. Replaced by its ticket's real
/// implementation, not extended in place.

/// Ticket 07 supplies the real `CGEventTap`-backed implementation.
final class PlaceholderKeyTap: KeyTapControlling {
    func startIntercepting() {}
}
