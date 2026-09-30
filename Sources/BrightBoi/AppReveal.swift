import Foundation

/// What BrightBoi does when something asks to see it: opening the app again
/// from Finder or Spotlight (a reopen), or a second copy starting and handing
/// over. The app has no Dock icon and no window of its own, so this is the way
/// back in when its menu bar item is hidden, for example behind the notch.
/// It brings onboarding forward if that is still up, and otherwise opens
/// Settings in front and key.
@MainActor
final class AppReveal {
    let settings: SettingsPresenter

    /// Brings onboarding forward and reports `true` if it is showing.
    var bringOnboardingForward: () -> Bool = { false }

    private let now: () -> Date
    private var lastReveal: Date?

    /// A Finder or Spotlight launch of a second copy can produce both a
    /// reopen event and the copy's hand-off. Requests closer together than
    /// this are one user action.
    static let coalesceWindow: TimeInterval = 0.5

    init(settings: SettingsPresenter, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.now = now
    }

    func reveal() {
        let current = now()
        if let last = lastReveal, current.timeIntervalSince(last) < Self.coalesceWindow { return }
        lastReveal = current
        if bringOnboardingForward() { return }
        settings.show()
    }

    /// The answer to `applicationShouldHandleReopen`: always `false`, because
    /// there is no window to restore and AppKit must not try to open one.
    func handleReopen() -> Bool {
        reveal()
        return false
    }

    /// Reveals whenever a second copy announces itself.
    @discardableResult
    func observeSecondLaunch(center: NotificationCenter = SingleInstanceGuard.systemCenter) -> NSObjectProtocol {
        SingleInstanceGuard.observeReveal(center: center) { [weak self] in
            self?.reveal()
        }
    }
}
