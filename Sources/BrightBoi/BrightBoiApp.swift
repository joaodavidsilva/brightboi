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

    var body: some Scene {
        MenuBarExtra {
            BrightnessMenuContent(controller: controller)
        } label: {
            BrightnessMenuBarIcon(controller: controller)
        }
        .menuBarExtraStyle(.window)

        // Placeholder scene so the popover's "Settings…" row has somewhere
        // to `SettingsLink` to — real content (Boost Ceiling, Key Remap,
        // Permissions panel) lands in ticket 02.
        Settings {
            Text("Settings coming soon.")
                .padding(40)
        }
    }
}
