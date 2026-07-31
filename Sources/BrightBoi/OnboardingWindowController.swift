import AppKit
import SwiftUI

/// Owns the first-run onboarding window. Built directly on `NSWindow`/
/// `NSHostingView` — same approach `BrightnessHUDController` uses for the
/// HUD — rather than a SwiftUI `Window` scene, since this window needs to
/// appear conditionally, exactly once at launch, not be openable on demand
/// the way a scene-backed window is. Unlike the HUD it's an ordinary
/// activating, key-taking window: onboarding needs real keyboard/mouse
/// interaction, not a click-through overlay.
@MainActor
final class OnboardingWindowController {
    private let window: NSWindow

    init(model: OnboardingModel) {
        let hostingView = NSHostingView(rootView: OnboardingView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: OnboardingView.contentSize)

        // `.closable` is deliberate even though closing this way doesn't
        // route through `OnboardingModel.complete()` — only finishing all
        // three steps or tapping "Skip" persists `hasCompletedOnboarding`
        // (per the spec), so dismissing via the native close button leaves
        // onboarding showing again next launch rather than silently
        // counting as "shown".
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        self.window = window

        model.onFinished = { [weak self] in
            self?.window.close()
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
