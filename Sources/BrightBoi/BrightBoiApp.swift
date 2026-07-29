import SwiftUI

@main
struct BrightBoiApp: App {
    var body: some Scene {
        MenuBarExtra {
            PlaceholderMenuContent()
        } label: {
            Image(systemName: "sun.max")
        }
        .menuBarExtraStyle(.window)
    }
}
