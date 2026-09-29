import AppKit
import SwiftUI

/// Owns every launch-time side effect BrightBoi has. `init` builds the
/// controller and the permissions snapshot with no side effects, so
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
    let permissions: PermissionsSnapshot

    private let persistence = RealBrightnessPersistence()
    private let hud = BrightnessHUDController()
    private var onboardingWindow: OnboardingWindowController?
    private var donationWindow: DonationWindowController?

    override init() {
        self.controller = BrightnessController(
            displayBrightness: LiveDisplayBrightnessProvider(),
            autoBrightnessToggle: RealAutoBrightnessToggle(),
            loginItemService: RealLoginItemService(),
            persistence: persistence,
            keyTap: RealKeyTap(),
            powerSource: RealPowerSourceProvider(),
            thermalState: RealThermalStateProvider()
        )
        self.permissions = PermissionsSnapshot(checker: RealPermissionsChecker())
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
        controller.onKeyPress = { [hud] _, state in
            hud.present(state: state)
        }
        controller.start()

        donationWindow = DonationWindowController(onClose: { [weak self] in
            self?.donationWindow = nil
        })
        donationWindow?.show()

        if OnboardingModel.shouldShow(persistence: persistence) {
            let model = OnboardingModel(persistence: persistence, permissionsChecker: RealPermissionsChecker())
            let window = OnboardingWindowController(model: model, onClose: { [weak self] in
                self?.onboardingWindow = nil
                NSApp.setActivationPolicy(.accessory)
            })
            onboardingWindow = window
            window.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.flushPendingPersist()
    }
}
