import SwiftUI

@main
struct BrightBoiApp: App {
    @State private var controller: BrightnessController

    // Captured once at app startup, per the spec's Permissions panel
    // decision (no polling, no refresh-on-window-focus).
    @State private var permissions = PermissionsSnapshot(checker: RealPermissionsChecker())

    // Owns the HUD's overlay window for the controller's whole lifetime;
    // not `@State`, since nothing in SwiftUI ever reads it — it only reacts
    // to `controller.onKeyPress` (ticket 03).
    private let hud: BrightnessHUDController

    init() {
        let controller = BrightnessController(
            displayBrightness: LiveDisplayBrightnessProvider(),
            autoBrightnessToggle: RealAutoBrightnessToggle(),
            loginItemService: RealLoginItemService(),
            persistence: RealBrightnessPersistence(),
            keyTap: RealKeyTap()
        )
        let hud = BrightnessHUDController()
        controller.onKeyPress = { [hud] _ in
            hud.present(state: controller.currentState)
        }
        self.hud = hud
        _controller = State(initialValue: controller)
    }

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
