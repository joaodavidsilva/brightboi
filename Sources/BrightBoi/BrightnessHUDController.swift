import AppKit
import SwiftUI

/// Owns the always-on-top, non-activating overlay window the HUD (ticket 03)
/// lives in. `BrightBoiApp` wires `present` to fire from
/// `BrightnessController.onKeyPress`, so it shows on every recognized key
/// press across the full 0...200% range — not just once Boosted — filling
/// the gap left by `RealKeyTap`'s `.defaultTap` already fully suppressing
/// macOS's native HUD with nothing shown in its place.
///
/// Built directly on `NSPanel`/`NSHostingView` rather than a SwiftUI
/// `Window` scene: a HUD needs `.nonactivatingPanel` (never activates the
/// app or becomes key, so it can't steal focus or block interaction with
/// whatever's underneath) and a status-bar-level, click-through window,
/// neither of which a SwiftUI scene can express.
@MainActor
final class BrightnessHUDController {
    /// Fraction of the screen's height the panel's bottom edge sits above,
    /// matching roughly where macOS's own native HUD sits.
    private static let verticalScreenFraction: CGFloat = 0.18

    private let panel: NSPanel
    private let hostingView: NSHostingView<BrightnessHUDView>
    private let autoDismissDelay: TimeInterval
    private var dismissWorkItem: DispatchWorkItem?

    init(autoDismissDelay: TimeInterval = 1.0) {
        self.autoDismissDelay = autoDismissDelay

        // Never actually shown — the panel starts ordered out and only
        // appears once `present(state:)` supplies a real state.
        let placeholderState = BrightnessController.State(
            percentage: 0,
            isBoosted: false,
            iconFillFraction: 0,
            supportsBoost: true,
            launchAtLoginEnabled: true,
            boostCeiling: BrightnessController.maximumPercentage,
            keyRemapEnabled: true,
            keyRemapShortcut: .defaultShortcut
        )
        let hostingView = NSHostingView(rootView: BrightnessHUDView(state: placeholderState))
        hostingView.frame = NSRect(origin: .zero, size: BrightnessHUDView.panelSize)
        self.hostingView = hostingView

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        self.panel = panel
    }

    /// Shows (or re-shows) the HUD with the given state and (re)schedules
    /// auto-dismissal `autoDismissDelay` seconds out. A press that arrives
    /// before that timer fires cancels and reschedules it, so the HUD stays
    /// up for `autoDismissDelay` seconds after the *last* press, not the
    /// first.
    func present(state: BrightnessController.State) {
        hostingView.rootView = BrightnessHUDView(state: state)
        positionOnMainScreen()
        panel.orderFrontRegardless()
        scheduleAutoDismiss()
    }

    private func positionOnMainScreen() {
        guard let screenFrame = NSScreen.main?.frame else { return }
        let size = BrightnessHUDView.panelSize
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY + screenFrame.height * Self.verticalScreenFraction
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func scheduleAutoDismiss() {
        dismissWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissDelay, execute: workItem)
    }
}
