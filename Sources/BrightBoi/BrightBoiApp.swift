import SwiftUI

@main
struct BrightBoiApp: App {
    // Owns every launch side effect, the menu bar item and every window,
    // including Settings — see `AppDelegate`. SwiftUI constructs it during
    // `App.init`, before `NSApplication` has finished launching, but
    // `AppDelegate.init` itself has no side effects, so that's safe.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // An app needs one scene. This one is inert: it has no content, and the
    // only thing it owns is the main menu's "Settings…" item, which opens the
    // app's own Settings window (Command-comma), the same as every other way
    // in. Nothing ever opens the scene's own window.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.settingsPresenter.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
