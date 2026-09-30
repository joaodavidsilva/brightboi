import AppKit
import SwiftUI

/// Owns the first-run onboarding window. Built directly on `NSWindow`/
/// `NSHostingView` — same approach `BrightnessHUDController` uses for the
/// HUD — rather than a SwiftUI `Window` scene, since this window needs to
/// appear conditionally, exactly once at launch, not be openable on demand
/// the way a scene-backed window is. Unlike the HUD it's an ordinary
/// activating, key-taking window: onboarding needs real keyboard/mouse
/// interaction, not a click-through overlay.
///
/// `onClose` fires from `windowWillClose` — whichever of `OnboardingModel`'s
/// completion, its own native close button, closes the window — so
/// `AppDelegate` can release its reference once onboarding is done, rather
/// than keeping this controller, the window and its SwiftUI graph alive for
/// the rest of the process.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void

    init(model: OnboardingModel, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let hostingView = NSHostingView(rootView: OnboardingView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: OnboardingView.contentSize)

        // `.closable` is deliberate even though closing this way doesn't
        // route through `OnboardingModel.complete()` — only finishing all
        // three steps or tapping "Skip" persists `hasCompletedOnboarding`,
        // so dismissing via the native close button leaves
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
        super.init()
        window.delegate = self

        model.onFinished = { [weak self] in
            self?.window.close()
        }
    }

    /// Brings the window back to the front, for when a permission was
    /// granted in System Settings and left this window behind it.
    func bringToFront() {
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    /// `NSApp.activate(ignoringOtherApps: true)` alone often leaves this
    /// LSUIElement app inactive and its window off the frontmost app's
    /// space — verified live with a full-screen terminal frontmost, the
    /// window stayed present but off-screen (confirmed via `CGWindowList`
    /// and a screenshot) until `.fullScreenAuxiliary` was added:
    /// `.moveToActiveSpace` alone moves a window to whatever ordinary space
    /// is active, but a *full-screen* space also needs
    /// `.fullScreenAuxiliary` before anything else is allowed to appear
    /// alongside it. `.floating` plus `orderFrontRegardless()` then makes it
    /// actually draw there; only a real click still makes it key, since
    /// keyboard focus isn't achievable while the app stays inactive.
    func show() {
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }
}
