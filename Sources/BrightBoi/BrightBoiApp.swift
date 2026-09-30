import SwiftUI

@main
struct BrightBoiApp: App {
    // Owns every launch side effect and every window that isn't scene-backed
    // — see `AppDelegate`. SwiftUI constructs it during `App.init`, before
    // `NSApplication` has finished launching, but `AppDelegate.init` itself
    // has no side effects, so that's safe.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            BrightnessMenuContent(
                controller: appDelegate.controller,
                updates: appDelegate.updates,
                settings: appDelegate.settingsPresenter
            )
        } label: {
            BrightnessMenuBarIcon(controller: appDelegate.controller, settings: appDelegate.settingsPresenter)
        }
        .menuBarExtraStyle(.window)

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
