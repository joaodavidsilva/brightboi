import AppKit
import SwiftUI

/// Owns the donation window (ticket 06). Shown unconditionally on every
/// launch — see ADR-0006 — after `BrightnessController.init()` has already
/// started the key remap and restored brightness (both synchronous side
/// effects of constructing it), so this window is non-blocking by
/// construction rather than by any runtime check here. The menu bar item
/// itself comes from the `MenuBarExtra` scene, which SwiftUI builds when it
/// reads `BrightBoiApp.body` right after `init()` returns — not sequenced
/// by this controller, but not delayed by it either.
///
/// Built directly on `NSWindow`/`NSHostingView`, same approach as
/// `OnboardingWindowController`, since this window also needs to appear on
/// demand at launch rather than be scene-backed.
@MainActor
final class DonationWindowController {
    private let window: NSWindow

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: DonationView.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        // Captures `window` weakly: `window` -> contentView -> hostingView
        // -> rootView holds this closure, so a strong capture would retain
        // `window` forever via itself.
        let hostingView = NSHostingView(rootView: DonationView(onDismiss: { [weak window] in
            window?.close()
        }))
        hostingView.frame = NSRect(origin: .zero, size: DonationView.contentSize)
        window.contentView = hostingView

        self.window = window
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
