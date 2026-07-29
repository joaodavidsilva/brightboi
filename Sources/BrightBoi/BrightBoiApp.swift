import SwiftUI

@main
struct BrightBoiApp: App {
    @State private var controller = BrightnessController(
        displayBrightness: LiveDisplayBrightnessProvider(),
        autoBrightnessToggle: PlaceholderAutoBrightnessToggle(),
        loginItemService: PlaceholderLoginItemService(),
        persistence: PlaceholderBrightnessPersistence(),
        keyTap: PlaceholderKeyTap()
    )

    var body: some Scene {
        MenuBarExtra {
            BrightnessMenuContent(controller: controller)
        } label: {
            BrightnessMenuBarIcon(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
