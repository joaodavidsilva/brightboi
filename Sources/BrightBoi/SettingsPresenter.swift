import AppKit
import SwiftUI

/// The one way BrightBoi opens its Settings window, whichever way the request
/// arrives: the popover's row, Command-comma, opening the app again from
/// Finder or Spotlight, or a second copy starting.
///
/// A menu bar app is never the active app when any of these happens, and an
/// inactive accessory app's new window opens behind whatever is in front, or
/// is neither key nor on screen over a full-screen app. So every request
/// closes the popover, activates the app, opens the window, and then orders
/// the window forward and makes it key.
///
/// The popover is hosted outside any scene, where SwiftUI's open-Settings
/// action is not reliably available, so the request goes down the responder
/// chain to the Settings menu command. The window is fronted as soon as it
/// reports in; it registers itself with `registersAsSettingsWindow`.
///
/// Closing the popover, activation, the responder-chain call and ordering the
/// window forward are injectable, so a test can drive every path without
/// touching the real app.
@MainActor
final class SettingsPresenter {
    private let activate: () -> Void
    private let openThroughResponderChain: () -> Bool
    private let front: (NSWindow) -> Void

    /// Runs first on every request, to put away the popover that may have
    /// asked for it.
    var willShow: () -> Void = {}
    private weak var window: NSWindow?
    /// While set and in the future, a Settings window that reports in is
    /// fronted: the request that asked for it is still recent. A request that
    /// produced no window (the responder chain found no target) must not let
    /// a much later, unrelated registration come forward unprompted.
    private var frontUntil: Date?
    private let now: () -> Date

    /// How long after a request a late window still counts as its answer.
    static let lateWindowGrace: TimeInterval = 3

    init(
        activate: @escaping () -> Void = { NSApplication.shared.activate(ignoringOtherApps: true) },
        openThroughResponderChain: @escaping () -> Bool = {
            SettingsPresenter.sendOpenAction { NSApplication.shared.sendAction($0, to: nil, from: nil) }
        },
        front: @escaping (NSWindow) -> Void = { window in
            window.orderFrontRegardless()
            window.makeKey()
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        self.activate = activate
        self.openThroughResponderChain = openThroughResponderChain
        self.front = front
    }

    /// Asks the responder chain to open Settings, with the current command and
    /// then the one older systems used. `send` reports whether a target took it.
    static func sendOpenAction(_ send: (Selector) -> Bool) -> Bool {
        send(Selector(("showSettingsWindow:"))) || send(Selector(("showPreferencesWindow:")))
    }

    /// Called by the Settings window's content when it lands in a window.
    func register(window: NSWindow) {
        self.window = window
        if let until = frontUntil {
            frontUntil = nil
            if now() < until { front(window) }
        }
    }

    /// Brings the app forward and opens Settings in front and key.
    func show() {
        willShow()
        activate()
        _ = openThroughResponderChain()
        if let window {
            front(window)
        } else {
            frontUntil = now().addingTimeInterval(Self.lateWindowGrace)
        }
    }
}

/// Reports the window its content ends up in.
private struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        Reader(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

extension View {
    /// Tells `presenter` which window this content lives in, so it can be
    /// ordered forward once opened.
    func registersAsSettingsWindow(_ presenter: SettingsPresenter) -> some View {
        background(WindowReader { window in
            MainActor.assumeIsolated { presenter.register(window: window) }
        })
    }
}
