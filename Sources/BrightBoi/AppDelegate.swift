import AppKit
import SwiftUI

/// Owns every launch-time side effect BrightBoi has. `init` builds the
/// controller and the permissions model with no side effects, so
/// `BrightBoiApp.body` — read right after `App.init` returns, before
/// `NSApplication` has finished launching — has something to construct its
/// scenes from immediately. Everything that actually touches the display,
/// the login item list, the key tap, or shows a window waits for
/// `applicationDidFinishLaunching`, once `NSApp` is the real
/// `AppKitApplication` SwiftUI expects rather than the plain `NSApplication`
/// creating a window during `App.init` would leave behind.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: BrightnessController
    let permissions: PermissionsModel

    private let persistence = RealBrightnessPersistence()
    private let hud = BrightnessHUDController()
    private var onboardingWindow: OnboardingWindowController?
    private var donationWindow: DonationWindowController?
    /// The clock and the time since the Mac started, for the donation prompt.
    /// Seams so the launch decision can be driven without real time.
    var now: () -> Date = { Date() }
    var systemUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    override init() {
        // A debug build (its own bundle identifier, so its own preferences)
        // starts without launching at login; turning it on in Settings still
        // registers it. Must run before the controller reads the setting.
        if Bundle.main.bundleIdentifier == "com.ptlghost.BrightBoi.dev" {
            UserDefaults.standard.register(defaults: [RealBrightnessPersistence.launchAtLoginEnabledKey: false])
        }
        let permissions = PermissionsModel(checker: RealPermissionsChecker())
        self.permissions = permissions
        self.controller = BrightnessController(
            displayBrightness: LiveDisplayBrightnessProvider(),
            autoBrightnessToggle: RealAutoBrightnessToggle(),
            loginItemService: RealLoginItemService(),
            persistence: persistence,
            keyTap: RealKeyTap(),
            powerSource: RealPowerSourceProvider(),
            thermalState: RealThermalStateProvider(),
            bundleLocation: RealBundleLocationProvider(),
            displayAccessibility: RealDisplayAccessibility(),
            permissions: permissions
        )
        super.init()
    }

    /// Onboarding needs real keyboard focus (Return/Esc without a click),
    /// which this `LSUIElement` (`.accessory`) app cannot reliably get by
    /// activating itself — a regular app reliably receives launch
    /// activation from Finder/LaunchServices, an accessory one does not.
    /// Switching to `.regular` only while onboarding will show, and only
    /// this early (before launch finishes, so the switch is in effect when
    /// LaunchServices delivers that activation), briefly shows a Dock icon
    /// for a first run; `applicationDidFinishLaunching` switches back to
    /// `.accessory` once onboarding's window closes.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if OnboardingModel.shouldShow(persistence: persistence) {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstanceGuard.acquire() else {
            // Another, equal-or-newer copy is already running — don't touch
            // brightness, gamma, auto-brightness, the login item or the key
            // tap. `SingleInstanceGuard.acquire()` already signaled it.
            exit(0)
        }

        SingleInstanceGuard.observeReveal { [weak self] in
            self?.revealApp()
        }

        controller.onKeyPress = { [hud] _, state in
            hud.present(state: state)
        }
        controller.start()
        permissions.startObservingSystemNotifications()
        // The onboarding window ends up behind System Settings while the user
        // grants access there; bring it back once the grant is seen.
        permissions.addGrantObserver { [weak self] in
            self?.onboardingWindow?.bringToFront()
        }

        let onboardingShowing = OnboardingModel.shouldShow(persistence: persistence)
        if DonationPromptPolicy.prepareLaunchPrompt(
            persistence: persistence,
            now: now(),
            systemUptime: systemUptime(),
            onboardingShowing: onboardingShowing
        ) {
            showDonationWindow()
        }

        if onboardingShowing {
            let model = OnboardingModel(persistence: persistence, permissions: permissions)
            let window = OnboardingWindowController(model: model, controller: controller, onClose: { [weak self] in
                self?.onboardingWindow = nil
                NSApp.setActivationPolicy(.accessory)
                // Whichever way onboarding ended, re-read the permissions so
                // the key tap comes up if access was granted meanwhile.
                self?.controller.permissionsMayHaveChanged()
            })
            onboardingWindow = window
            window.show()
        }
    }

    /// Shows the donation window, creating it if needed. Used by the
    /// throttled launch prompt and by Settings' "Support BrightBoi…", which
    /// ignores the throttle and records nothing. The window never takes focus.
    func showDonationWindow() {
        if donationWindow == nil {
            donationWindow = DonationWindowController(onClose: { [weak self] in
                self?.donationWindow = nil
            })
        }
        donationWindow?.show()
    }

    /// Launching BrightBoi again (Finder, Spotlight, `open`) is the way back in
    /// when its menu bar item is hidden, for example behind the notch. The app
    /// has no Dock icon and no window of its own to show, so it opens
    /// Settings, unless onboarding is up, which is brought forward instead.
    /// Returning `false` stops AppKit from also trying to open a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealApp()
        return false
    }

    private func revealApp() {
        if let onboardingWindow {
            onboardingWindow.bringToFront()
        } else {
            NotificationCenter.default.post(name: BrightnessMenuBarIcon.openSettingsRequested, object: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.flushPendingPersist()
        controller.restoreSystemStateOnTermination()
    }
}
