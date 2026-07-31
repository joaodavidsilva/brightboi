import SwiftUI

@main
struct BrightBoiApp: App {
    @State private var controller = BrightnessController(
        displayBrightness: LiveDisplayBrightnessProvider(),
        autoBrightnessToggle: RealAutoBrightnessToggle(),
        loginItemService: RealLoginItemService(),
        persistence: RealBrightnessPersistence(),
        keyTap: RealKeyTap()
    )

    // Captured once at app startup, per the spec's Permissions panel
    // decision (no polling, no refresh-on-window-focus).
    @State private var permissions = PermissionsSnapshot(checker: RealPermissionsChecker())

    var body: some Scene {
        MenuBarExtra {
            BrightnessMenuContent(controller: controller)
        } label: {
            BrightnessMenuBarIcon(controller: controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller, permissions: permissions)
        }
    }
}
