import AppKit
import Observation
import SwiftUI

/// Whether the donation window is currently key, read by `DonationView` to
/// decide whether its "or press Esc" hint would actually be true. The
/// window never calls `NSApp.activate`, so it starts non-key and only
/// becomes key if the user clicks into it.
@Observable
@MainActor
final class DonationWindowKeyState {
    var isKey = false
}

/// A single click on this window both activates BrightBoi (the normal AppKit
/// behavior for any click on an inactive app's window) and reaches the
/// SwiftUI control under the pointer, rather than being swallowed as a pure
/// activation click — `acceptsFirstMouse(for:)` is consulted on the view a
/// click actually hits, `NSHostingView` here, not on the window itself.
/// Without this, the first click on "Not today" would only bring the app
/// forward and need a second click to actually dismiss it, since
/// `DonationWindowController` never calls `NSApp.activate` on its own.
private final class ClickThroughActivationHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the donation window. `AppDelegate` shows it from the throttled
/// launch prompt, after `BrightnessController.start()` has already applied
/// the restored brightness and started the key remap, and on request from
/// Settings, so this window is non-blocking by construction rather than by
/// any runtime check here.
///
/// Deliberately never takes focus: `show()` only orders the window front —
/// never `NSApp.activate` or `makeKeyAndOrderFront` — so whatever app the
/// user had frontmost keeps keyboard focus. `.floating` plus
/// `[.moveToActiveSpace, .fullScreenAuxiliary]` mirrors
/// `OnboardingWindowController`'s fix for the same "off the active space
/// behind a full-screen app" problem, minus the activation that window still
/// needs for its own keyboard interaction.
///
/// Built directly on `NSWindow`/`NSHostingView`, same approach as
/// `OnboardingWindowController`, since this window also needs to appear on
/// demand at launch rather than be scene-backed. `onClose` fires from
/// `windowWillClose` — whether the window closed via `DonationView`'s own
/// dismiss button or the native close button — so `AppDelegate` can release
/// its reference and let this controller, the window and its SwiftUI graph
/// deallocate instead of living for the rest of the process.
@MainActor
final class DonationWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let keyState = DonationWindowKeyState()
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: DonationView.contentWidth, height: 1),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Support BrightBoi"
        window.titleVisibility = .hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Captures `window` weakly: `window` -> contentView -> hostingView
        // -> rootView holds this closure, so a strong capture would retain
        // `window` forever via itself.
        let hostingView = ClickThroughActivationHostingView(rootView: DonationView(
            keyState: keyState,
            onDismiss: { [weak window] in
                window?.close()
            }
        ))
        // The window is as tall as its content, so there is no dead space
        // however the text wraps.
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.center()

        self.window = window
        super.init()
        window.delegate = self
    }

    /// The name assistive technology announces for the window. The title bar
    /// hides it, so it is never drawn.
    var windowTitle: String { window.title }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        keyState.isKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        keyState.isKey = false
    }

    func show() {
        window.orderFrontRegardless()
    }
}
