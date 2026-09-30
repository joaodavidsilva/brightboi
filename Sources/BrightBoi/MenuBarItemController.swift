import AppKit
import SwiftUI

/// The menu bar item's button, as far as `MenuBarItemController` needs it.
/// The real one is an `NSStatusItem`'s button; a test supplies a plain button,
/// since a status bar item cannot exist without a real menu bar.
@MainActor
protocol StatusItemHosting: AnyObject {
    var button: NSButton { get }
}

/// The popover the menu bar item opens.
@MainActor
protocol PopoverHosting: AnyObject {
    var isShown: Bool { get }
    /// Runs just before the popover appears, however it was opened.
    var willShow: (() -> Void)? { get set }
    /// Runs as the popover starts to close, however it was closed.
    var willClose: (() -> Void)? { get set }
    func show(relativeTo button: NSButton)
    func close()
}

/// The target of the status button's action. Pressing the button, with the
/// mouse or through the accessibility action AXPress, sends it here.
@MainActor
final class StatusButtonPressTarget: NSObject {
    var onPress: () -> Void = {}

    @objc func pressed(_ sender: Any?) {
        onPress()
    }
}

/// Owns the menu bar item: its glyph and spoken label follow the controller,
/// and pressing it opens or closes the popover.
///
/// The item is an `NSStatusItem` rather than a SwiftUI `MenuBarExtra`, because
/// the `MenuBarExtra` button has no action of its own, so assistive clients
/// that press it (VoiceOver, Voice Control, System Events) could not open the
/// popover. The button here has a target and action, so AXPress is the same
/// as a click.
@MainActor
final class MenuBarItemController {
    private let controller: BrightnessController
    private let makeItem: () -> StatusItemHosting?
    private let popover: PopoverHosting
    private let pressTarget = StatusButtonPressTarget()
    private let now: () -> Date

    private var item: StatusItemHosting?
    /// Set while this controller is closing the popover itself, so the close
    /// is not mistaken for a dismissal by the user.
    private var closingByToggle = false
    private var lastDismissal: Date?

    /// A press this soon after the user dismissed the popover is the same
    /// click: a transient popover closes on the mouse-down, and the button's
    /// action then arrives on the mouse-up, which would reopen it at once.
    static let dismissalGrace: TimeInterval = 0.25

    init(
        controller: BrightnessController,
        popover: PopoverHosting,
        settings: SettingsPresenter,
        makeItem: @escaping () -> StatusItemHosting?,
        now: @escaping () -> Date = Date.init
    ) {
        self.controller = controller
        self.popover = popover
        self.makeItem = makeItem
        self.now = now
        pressTarget.onPress = { [weak self] in self?.toggle() }
        popover.willShow = { [weak self] in self?.prepareToShow() }
        popover.willClose = { [weak self] in self?.popoverWillClose() }
        // Settings opens in front of everything, so the popover makes way.
        settings.willShow = { [weak self] in self?.closePopover() }
    }

    /// Creates the status item, once. Later calls do nothing.
    func install() {
        guard item == nil else { return }
        guard let item = makeItem() else {
            Log.menuBar.error("The status bar gave no button, so there is no menu bar item")
            return
        }
        self.item = item
        let button = item.button
        button.imagePosition = .imageOnly
        button.target = pressTarget
        button.action = #selector(StatusButtonPressTarget.pressed(_:))
        refresh()
    }

    var isInstalled: Bool { item != nil }

    var isPopoverShown: Bool { popover.isShown }

    /// Opens the popover, or closes it if it is open.
    func toggle() {
        guard let item else { return }
        if let last = lastDismissal, now().timeIntervalSince(last) < Self.dismissalGrace {
            // The click that dismissed the popover, arriving as its action.
            lastDismissal = nil
        } else if popover.isShown {
            closingByToggle = true
            popover.close()
        } else {
            popover.show(relativeTo: item.button)
        }
    }

    /// Closes the popover if it is open.
    func closePopover() {
        guard popover.isShown else { return }
        closingByToggle = true
        popover.close()
    }

    /// Puts the glyph and the spoken label in step with the controller, and
    /// asks to be called again when its state next changes.
    func refresh() {
        let state = withObservationTracking {
            controller.currentState
        } onChange: { [weak self] in
            // Fires before the change lands, so look again once it has.
            Task { @MainActor in self?.refresh() }
        }
        guard let button = item?.button else { return }
        let label = BrightnessMenuBarIcon.accessibilityLabel(percentage: state.percentage, isBoosted: state.isBoosted)
        button.image = BrightnessMenuBarIcon.image(
            fraction: state.iconFillFraction,
            isBoosted: state.isBoosted,
            description: label
        )
        button.setAccessibilityLabel(label)
    }

    /// What the popover needs before it shows: the display may have changed,
    /// or a permission been granted, while it was closed.
    private func prepareToShow() {
        controller.syncFromDisplay()
        controller.permissionsMayHaveChanged()
    }

    /// Stamped as the close begins, not when it ends: the closing animation
    /// can outlast the mouse-up that follows the click.
    private func popoverWillClose() {
        if closingByToggle {
            closingByToggle = false
        } else {
            lastDismissal = now()
        }
    }
}

// MARK: - System implementations

/// The real status bar item.
@MainActor
final class SystemStatusItem: StatusItemHosting {
    private let statusItem: NSStatusItem
    let button: NSButton

    init?() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else {
            NSStatusBar.system.removeStatusItem(statusItem)
            return nil
        }
        // Lets the system remember where the user put the item.
        statusItem.autosaveName = "BrightBoi"
        self.statusItem = statusItem
        self.button = button
    }
}

/// Installs event monitors; the real one talks to `NSEvent`, a test counts.
@MainActor
protocol EventMonitoring: AnyObject {
    func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any?
    func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any?
    func remove(_ token: Any)
}

/// The real monitors, backed by `NSEvent`.
@MainActor
final class SystemEventMonitors: EventMonitoring {
    func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            // Local monitors run on the main thread; the event only passes through.
            nonisolated(unsafe) var result: NSEvent?
            MainActor.assumeIsolated { result = handler(event) }
            return result
        }
    }

    func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { handler(event) }
        }
    }

    func remove(_ token: Any) {
        NSEvent.removeMonitor(token)
    }
}

/// Decides when an open popover should close, without relying on the app
/// being active. A transient popover closes whenever the app resigns, and an
/// accessory app opened by an assistive client (AXPress) is handed back
/// activation at once, so the popover would vanish the moment it appeared.
/// Instead the popover stays open until something explicit closes it: a mouse
/// down outside it and outside the status button, Esc, the screen
/// configuration changing, or the app quitting.
///
/// Monitors and observers exist only between `start()` and `stop()`.
@MainActor
final class PopoverDismissal {
    private let monitors: EventMonitoring
    private let notifications: NotificationCenter
    private let insideFrames: () -> [NSRect]
    private let popoverWindow: () -> NSWindow?
    private let close: () -> Void

    private var tokens: [Any] = []
    private var observers: [NSObjectProtocol] = []

    static let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    static let escapeKeyCode: UInt16 = 53

    /// - Parameters:
    ///   - insideFrames: screen frames where a mouse down does not dismiss
    ///     (the popover and the status button).
    ///   - popoverWindow: the popover's window, which Esc is read in.
    init(
        monitors: EventMonitoring = SystemEventMonitors(),
        notifications: NotificationCenter = .default,
        insideFrames: @escaping () -> [NSRect],
        popoverWindow: @escaping () -> NSWindow?,
        close: @escaping () -> Void
    ) {
        self.monitors = monitors
        self.notifications = notifications
        self.insideFrames = insideFrames
        self.popoverWindow = popoverWindow
        self.close = close
    }

    var isActive: Bool { !tokens.isEmpty || !observers.isEmpty }

    func start() {
        guard !isActive else { return }
        if let token = monitors.addLocal(matching: Self.mouseDowns, handler: { [weak self] event in
            self?.mouseDown(event)
            return event
        }) { tokens.append(token) }
        if let token = monitors.addGlobal(matching: Self.mouseDowns, handler: { [weak self] event in
            self?.mouseDown(event)
        }) { tokens.append(token) }
        if let token = monitors.addLocal(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            return self.keyDown(event)
        }) { tokens.append(token) }
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.willTerminateNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
    }

    func stop() {
        for token in tokens { monitors.remove(token) }
        tokens = []
        for observer in observers { notifications.removeObserver(observer) }
        observers = []
    }

    private func mouseDown(_ event: NSEvent) {
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if insideFrames().contains(where: { $0.contains(point) }) { return }
        close()
    }

    private func keyDown(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == Self.escapeKeyCode,
              event.window == nil || event.window === popoverWindow() else { return event }
        close()
        return nil
    }
}

/// An `NSPopover` hosting the popover content. It is `.applicationDefined`,
/// so it does not close when the app resigns; `PopoverDismissal` closes it.
@MainActor
final class SystemPopover: NSObject, PopoverHosting, NSPopoverDelegate {
    let popover = NSPopover()
    var willShow: (() -> Void)?
    var willClose: (() -> Void)?
    private var dismissal: PopoverDismissal?
    private weak var anchor: NSButton?

    init(content: NSViewController, monitors: EventMonitoring = SystemEventMonitors()) {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = content
        popover.delegate = self
        dismissal = PopoverDismissal(
            monitors: monitors,
            insideFrames: { [weak self] in self?.insideFrames() ?? [] },
            popoverWindow: { [weak self] in self?.popover.contentViewController?.view.window },
            close: { [weak self] in self?.close() }
        )
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo button: NSButton) {
        anchor = button
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A real click activates the app, which is harmless; an assistive
        // client's press may not be granted activation, and the popover does
        // not depend on it. Either way the popover takes key focus itself, so
        // Esc and keyboard navigation work.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.close()
    }

    /// Where a mouse down is not a dismissal: the popover and the button that
    /// toggles it, whose own action handles the click.
    private func insideFrames() -> [NSRect] {
        var frames: [NSRect] = []
        if let window = popover.contentViewController?.view.window { frames.append(window.frame) }
        if let button = anchor, let window = button.window {
            frames.append(window.convertToScreen(button.convert(button.bounds, to: nil)))
        }
        return frames
    }

    func popoverWillShow(_ notification: Notification) {
        willShow?()
        dismissal?.start()
    }

    func popoverWillClose(_ notification: Notification) {
        dismissal?.stop()
        willClose?()
    }
}

extension MenuBarItemController {
    /// The controller wired to the real status bar and the real popover.
    static func live(
        controller: BrightnessController,
        updates: UpdateChecker?,
        settings: SettingsPresenter
    ) -> MenuBarItemController {
        let host = NSHostingController(rootView: BrightnessMenuContent(
            controller: controller,
            updates: updates,
            settings: settings
        ))
        // The popover follows the content's height, for banners that come and go.
        host.sizingOptions = .preferredContentSize
        return MenuBarItemController(
            controller: controller,
            popover: SystemPopover(content: host),
            settings: settings,
            makeItem: { SystemStatusItem() }
        )
    }
}
