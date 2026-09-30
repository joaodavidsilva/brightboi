import SwiftUI

@main
struct BrightBoiApp: App {
    // Owns every launch side effect, the menu bar item and every window that
    // isn't scene-backed — see `AppDelegate`. SwiftUI constructs it during
    // `App.init`, before `NSApplication` has finished launching, but
    // `AppDelegate.init` itself has no side effects, so that's safe.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                controller: appDelegate.controller,
                permissions: appDelegate.permissions,
                onShowSupport: { appDelegate.showDonationWindow() },
                updates: appDelegate.updates
            )
            .registersAsSettingsWindow(appDelegate.settingsPresenter)
        }
    }
}
