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

/// An `NSPopover` that closes on a click outside it and on Esc, hosting the
/// popover content.
@MainActor
final class SystemPopover: NSObject, PopoverHosting, NSPopoverDelegate {
    let popover = NSPopover()
    var willShow: (() -> Void)?
    var willClose: (() -> Void)?

    init(content: NSViewController) {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = content
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo button: NSButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // An accessory app is not active when its item is pressed; without
        // this the popover is not key and ignores Esc and its shortcuts.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.close()
    }

    func popoverWillShow(_ notification: Notification) {
        willShow?()
    }

    func popoverWillClose(_ notification: Notification) {
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
