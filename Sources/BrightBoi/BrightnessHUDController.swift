import AppKit
import SwiftUI

/// What the HUD panel is doing, as a pure state machine so the fade rules can
/// be tested without a window. A press while the HUD is hidden fades it in;
/// a press while it is visible, or already fading out, snaps it back to fully
/// opaque instead. Every change of intent bumps `generation`, so the
/// completion of a fade-out that has since been overtaken can tell it is
/// stale and must not order the panel out.
struct HUDFadeMachine: Equatable {
    enum Phase: Equatable {
        case hidden
        case visible
        case fadingOut
    }

    enum ShowAction: Equatable {
        /// Start from transparent and fade in.
        case fadeIn
        /// Already on screen: go straight to opaque, cancelling any fade-out.
        case snapOpaque
    }

    private(set) var phase: Phase = .hidden
    private(set) var generation = 0

    mutating func show() -> ShowAction {
        generation += 1
        let action: ShowAction = phase == .hidden ? .fadeIn : .snapOpaque
        phase = .visible
        return action
    }

    /// Forgets the panel as hidden, and overtakes any fade still running.
    mutating func reset() {
        generation += 1
        phase = .hidden
    }

    /// Starts the fade-out, returning the generation its completion must
    /// still match, or `nil` when there is nothing visible to fade.
    mutating func beginDismiss() -> Int? {
        guard phase == .visible else { return nil }
        generation += 1
        phase = .fadingOut
        return generation
    }

    /// Whether a fade-out that captured `generation` should now order the
    /// panel out. `false` when a newer press has overtaken it.
    mutating func finishDismiss(generation captured: Int) -> Bool {
        guard captured == generation, phase == .fadingOut else { return false }
        phase = .hidden
        return true
    }
}

/// Everything the HUD reaches for outside its own panel, so a test can drive
/// it without a screen, real time, real animation or an assistive technology
/// listening.
struct HUDEnvironment {
    /// Where the panel's bottom-left corner goes, or `nil` when the HUD must
    /// stay away (the built-in display is not active).
    var origin: @MainActor () -> CGPoint?
    var reduceMotion: @MainActor () -> Bool
    /// Runs `work` after `delay` seconds and returns a closure that cancels it.
    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    /// Animates the panel's alpha to `alpha` over `duration`, then calls
    /// `completion`. A zero duration replaces any animation still running.
    var animateAlpha: @MainActor (NSPanel, CGFloat, TimeInterval, (@MainActor () -> Void)?) -> Void
    /// Posts one accessibility notification for `element`.
    var postAccessibility: @MainActor (Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]) -> Void

    static let live = HUDEnvironment(
        origin: { BrightnessHUDController.builtInOrigin() },
        reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        schedule: { delay, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        },
        animateAlpha: { panel, alpha, duration, completion in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                panel.animator().alphaValue = alpha
            } completionHandler: {
                guard let completion else { return }
                MainActor.assumeIsolated { completion() }
            }
        },
        postAccessibility: { element, notification, userInfo in
            NSAccessibility.post(element: element, notification: notification, userInfo: userInfo)
        }
    )
}

/// Owns the always-on-top, non-activating overlay window the HUD lives in.
/// `AppDelegate` wires `present` to fire from `BrightnessController.onKeyPress`,
/// so it shows on every recognized key press across the full 0...200% range,
/// not just once Boosted, filling the gap left by `RealKeyTap`'s `.defaultTap`
/// swallowing the keys so that macOS's own indicator never appears.
///
/// Built directly on `NSPanel`/`NSHostingView` rather than a SwiftUI
/// `Window` scene: a HUD needs `.nonactivatingPanel` (never activates the
/// app or becomes key, so it can't steal focus or block interaction with
/// whatever's underneath) and a status-bar-level, click-through window,
/// neither of which a SwiftUI scene can express.
///
/// It always appears on the built-in display, the one whose brightness the
/// keys change, wherever keyboard focus happens to be, and stays away when
/// that display is not active.
@MainActor
final class BrightnessHUDController {
    /// Fraction of the screen's usable height the panel's bottom edge sits
    /// above, matching roughly where macOS's own native HUD sits.
    private static let verticalScreenFraction: CGFloat = 0.18
    static let fadeInDuration: TimeInterval = 0.12
    static let fadeOutDuration: TimeInterval = 0.35
    /// A burst of presses is announced once, this long after the last.
    static let announcementDebounce: TimeInterval = 0.3

    let panel: NSPanel
    private let hostingView: NSHostingView<BrightnessHUDView>
    private let autoDismissDelay: TimeInterval
    private let environment: HUDEnvironment
    private var cancelDismiss: (@MainActor () -> Void)?
    private var cancelAnnouncement: (@MainActor () -> Void)?
    private var fade = HUDFadeMachine()

    init(autoDismissDelay: TimeInterval = 1.0, environment: HUDEnvironment = .live) {
        self.autoDismissDelay = autoDismissDelay
        self.environment = environment

        // Never actually shown — the panel starts ordered out and only
        // appears once `present(state:)` supplies a real state.
        let placeholderState = BrightnessController.State(
            percentage: 0,
            isBoosted: false,
            iconFillFraction: 0,
            supportsBoost: true,
            launchAtLoginEnabled: true,
            launchAtLoginNeedsApproval: false,
            launchAtLoginStatusMessage: nil,
            boostCeiling: BrightnessController.maximumPercentage,
            keyRemapEnabled: true,
            keyRemapShortcut: .defaultShortcut,
            autoBrightnessTakeoverEnabled: true,
            boostBlockedByOtherApp: false
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

    // MARK: - Pure helpers

    /// Where the panel's bottom-left corner goes: centred horizontally on the
    /// built-in screen's usable area, with its bottom edge 18% of that area's
    /// height above the bottom. `nil` when none of `screens` is built in, so
    /// the HUD is never drawn on an external monitor by mistake. The built-in
    /// screen wins wherever it sits in the list.
    static func hudOrigin(
        panelSize: CGSize,
        screens: [(id: CGDirectDisplayID, visibleFrame: CGRect)],
        isBuiltin: (CGDirectDisplayID) -> Bool
    ) -> CGPoint? {
        guard let frame = screens.first(where: { isBuiltin($0.id) })?.visibleFrame else { return nil }
        return CGPoint(
            x: frame.midX - panelSize.width / 2,
            y: frame.minY + frame.height * verticalScreenFraction
        )
    }

    /// The fade durations, in seconds, as (in, out). Reduce Motion skips the
    /// fade entirely.
    static func fadeDurations(reduceMotion: Bool) -> (fadeIn: TimeInterval, fadeOut: TimeInterval) {
        reduceMotion ? (0, 0) : (fadeInDuration, fadeOutDuration)
    }

    /// What VoiceOver says for a key press: the level, then whether it is
    /// boosted, and whether the press ran into an end of the range. The top
    /// of the range is the Boost Ceiling on a Mac that can boost, and 100%
    /// on one that cannot.
    static func announcementText(
        percentage: Double,
        isBoosted: Bool,
        supportsBoost: Bool,
        boostCeiling: Double
    ) -> String {
        var text = "Brightness \(Int(percentage.rounded())) percent"
        if isBoosted { text += ", boosted" }
        let maximum = supportsBoost ? boostCeiling : BrightnessController.nominalCeilingPercentage
        if percentage >= maximum {
            text += ", maximum"
        } else if percentage <= 0 {
            text += ", minimum"
        }
        return text
    }

    // MARK: - Presenting

    /// Shows (or re-shows) the HUD with the given state and (re)schedules
    /// auto-dismissal `autoDismissDelay` seconds out. A press that arrives
    /// before that timer fires cancels and reschedules it, so the HUD stays
    /// up for `autoDismissDelay` seconds after the *last* press, not the
    /// first. Does nothing while the built-in display is not active.
    func present(state: BrightnessController.State) {
        guard let origin = environment.origin() else { return }

        hostingView.rootView = BrightnessHUDView(state: state)
        panel.setFrameOrigin(origin)

        let durations = Self.fadeDurations(reduceMotion: environment.reduceMotion())
        switch fade.show() {
        case .fadeIn:
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            environment.animateAlpha(panel, 1, durations.fadeIn, nil)
        case .snapOpaque:
            // Zero-duration group: replaces any fade-out still running, so
            // its completion cannot order the panel out from under us.
            environment.animateAlpha(panel, 1, 0, nil)
            panel.orderFrontRegardless()
        }
        scheduleAutoDismiss()
        announce(state: state)
    }

    /// Orders the panel out at once, with no fade and no announcement still
    /// pending. For the end of a test, and for anything that must not leave
    /// the HUD behind.
    func hideImmediately() {
        cancelDismiss?()
        cancelDismiss = nil
        cancelAnnouncement?()
        cancelAnnouncement = nil
        fade.reset()
        panel.orderOut(nil)
    }

    static func builtInOrigin() -> CGPoint? {
        guard let builtInID = BuiltInDisplay.resolveID(), BuiltInDisplay.isActive(builtInID) else { return nil }
        let screens = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, visibleFrame: CGRect)? in
            BuiltInDisplay.screenNumber(of: screen).map { (id: $0, visibleFrame: screen.visibleFrame) }
        }
        return hudOrigin(
            panelSize: BrightnessHUDView.panelSize,
            screens: screens,
            isBuiltin: { $0 == builtInID }
        )
    }

    private func scheduleAutoDismiss() {
        cancelDismiss?()
        cancelDismiss = environment.schedule(autoDismissDelay) { [weak self] in
            self?.dismiss()
        }
    }

    /// Reduce Motion is read when the fade starts, not when it was scheduled,
    /// so switching it on while the HUD is up applies to its fade-out.
    private func dismiss() {
        guard let generation = fade.beginDismiss() else { return }
        let fadeOutDuration = Self.fadeDurations(reduceMotion: environment.reduceMotion()).fadeOut
        environment.animateAlpha(panel, 0, fadeOutDuration) { [weak self] in
            guard let self, self.fade.finishDismiss(generation: generation) else { return }
            self.panel.orderOut(nil)
        }
    }

    // MARK: - VoiceOver

    /// The accessibility element an announcement is posted for: the
    /// application itself. BrightBoi is an accessory app that is never
    /// frontmost when its keys are pressed, and is not key anywhere, so no
    /// window of its could stand in for it.
    static var announcementElement: Any { NSApplication.shared }

    /// What goes with the announcement. High priority interrupts one still
    /// being spoken, so a burst of presses ends on the last value.
    static func announcementUserInfo(text: String) -> [NSAccessibility.NotificationUserInfoKey: Any] {
        [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ]
    }

    /// The HUD itself is hidden from accessibility and the keys it answers
    /// are swallowed, so nothing else tells a VoiceOver user the new level.
    /// Held-key repeats arrive faster than speech can follow, so a burst of
    /// presses is announced once, after the last one.
    private func announce(state: BrightnessController.State) {
        let text = Self.announcementText(
            percentage: state.percentage,
            isBoosted: state.isBoosted,
            supportsBoost: state.supportsBoost,
            boostCeiling: state.boostCeiling
        )
        cancelAnnouncement?()
        cancelAnnouncement = environment.schedule(Self.announcementDebounce) { [environment] in
            environment.postAccessibility(
                Self.announcementElement,
                .announcementRequested,
                Self.announcementUserInfo(text: text)
            )
        }
    }
}
