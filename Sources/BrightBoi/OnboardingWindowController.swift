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
/// `windowWillClose` runs however the window closes, whether the model
/// finished or the native close button was used. It tells the model, so
/// closing on any step counts as having seen onboarding, then calls
/// `onClose` so `AppDelegate` can release its reference rather than keeping
/// this controller, the window and its SwiftUI graph alive for the rest of
/// the process.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: OnboardingModel
    private let onClose: () -> Void

    /// `controller` is only read, live, for what the last step can truthfully
    /// say: whether this Mac supports Boost and whether the brightness keys
    /// are being taken over.
    init(model: OnboardingModel, controller: BrightnessController, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose

        let hostingView = NSHostingView(rootView: OnboardingHost(model: model, controller: controller))
        hostingView.frame = NSRect(origin: .zero, size: OnboardingView.contentSize)

        // `.closable` stays: closing the window on any step is a way out,
        // and `windowWillClose` records it as seen.
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to BrightBoi"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
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
    /// granted in System Settings and left this window behind it. It only
    /// orders the window forward: activating the app would be refused under
    /// cooperative activation on macOS 14 and later, and would pull keyboard
    /// focus away from the pane while the user is still in it.
    func bringToFront() {
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        model.dismissedByClose()
        onClose()
    }

    /// Shows the window and makes it key, so Return and Esc work without a
    /// click. `AppDelegate` switches the app to a regular one while
    /// onboarding will show, which is what lets a launch from Finder hand it
    /// activation. `.moveToActiveSpace` plus `.fullScreenAuxiliary` keep the
    /// window on whichever space is active, including a full-screen one, and
    /// `.floating` keeps it from ending up behind other apps' windows.
    func show() {
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }
}

/// Reads the controller inside a view body, so the last step follows the
/// key tap coming up (or not) while onboarding is open, and hands
/// `OnboardingView` plain values.
private struct OnboardingHost: View {
    var model: OnboardingModel
    var controller: BrightnessController

    var body: some View {
        OnboardingView(
            model: model,
            supportsBoost: controller.currentState.supportsBoost,
            keyRemapActive: controller.keyRemapActive
        )
    }
}
