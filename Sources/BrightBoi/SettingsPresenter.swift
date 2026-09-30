import AppKit
import SwiftUI

/// The one way BrightBoi opens its Settings window, whichever way the request
/// arrives: the popover's row, Command-comma, opening the app again from
/// Finder or Spotlight, or a second copy starting.
///
/// The window is owned here, not by a SwiftUI `Settings` scene. A scene's
/// open action needs a window or a main menu to be handled, and this
/// accessory app has neither while only its menu bar item is showing, so the
/// request had nowhere to land. An `NSWindow` that this class creates and
/// orders forward itself cannot fail that way.
///
/// A menu bar app is never the active app when a request arrives, and an
/// inactive accessory app's window opens behind whatever is in front, or is
/// neither key nor on screen over a full-screen app. So every request closes
/// the popover, asks to activate the app, and then orders the window forward
/// and makes it key, without depending on the activation being granted.
///
/// There is at most one window: a request while it is open brings that one
/// forward, and closing it releases it.
///
/// Closing the popover, activation, creating the window and ordering it
/// forward are injectable, so a test can drive every path without touching
/// the real app.
@MainActor
final class SettingsPresenter {
    private let makeWindow: () -> NSWindow
    private let activate: () -> Void
    private let front: (NSWindow) -> Void
    private let notifications: NotificationCenter

    /// Runs first on every request, to put away the popover that may have
    /// asked for it.
    var willShow: () -> Void = {}
    /// The open Settings window, if there is one.
    private(set) var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(
        makeWindow: @escaping () -> NSWindow,
        activate: @escaping () -> Void = { NSApplication.shared.activate(ignoringOtherApps: true) },
        front: @escaping (NSWindow) -> Void = { window in
            window.orderFrontRegardless()
            window.makeKey()
        },
        notifications: NotificationCenter = .default
    ) {
        self.makeWindow = makeWindow
        self.activate = activate
        self.front = front
        self.notifications = notifications
    }

    /// Brings the app forward and opens Settings in front and key.
    func show() {
        willShow()
        activate()
        let window = openWindow()
        front(window)
    }

    /// The open window, or a new one if there is none.
    private func openWindow() -> NSWindow {
        if let window { return window }
        let window = makeWindow()
        self.window = window
        closeObserver = notifications.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowClosed() }
        }
        return window
    }

    private func windowClosed() {
        if let closeObserver { notifications.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
    }
}

/// Builds the Settings window around `SettingsView`.
enum SettingsWindow {
    static let title = "BrightBoi Settings"

    @MainActor
    static func make(
        controller: BrightnessController,
        permissions: PermissionsModel,
        onShowSupport: @escaping () -> Void,
        updates: UpdateChecker?
    ) -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(
            controller: controller,
            permissions: permissions,
            onShowSupport: onShowSupport,
            updates: updates
        ))
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // Opens on the space the user is on, and over a full-screen app.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setContentSize(host.view.fittingSize)
        window.center()
        return window
    }
}
