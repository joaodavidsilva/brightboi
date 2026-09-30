import AppKit
import Testing
@testable import BrightBoi

/// A status item that is only a button, since a real one needs a real menu bar.
@MainActor
final class FakeStatusItem: StatusItemHosting {
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
}

/// A popover that only keeps score. `dismissFromOutside` stands for a click
/// outside it or Esc, which a transient popover handles by closing itself.
@MainActor
final class FakePopover: PopoverHosting {
    private(set) var isShown = false
    private(set) var showCount = 0
    private(set) var anchors: [NSButton] = []
    var willShow: (() -> Void)?
    var willClose: (() -> Void)?
    private(set) var closeReasons: [PopoverCloseReason] = []

    func show(relativeTo button: NSButton) {
        willShow?()
        isShown = true
        showCount += 1
        anchors.append(button)
    }

    func close(reason: PopoverCloseReason) {
        guard isShown else { return }
        closeReasons.append(reason)
        willClose?()
        isShown = false
    }

    func dismissFromOutside() { close(reason: .outsideClick) }

    /// A close that has started but whose animation is still running.
    func beginDismissal() { willClose?() }
    func finishDismissal() { isShown = false }
}

@MainActor
private final class MenuBarRig {
    let rig: ControllerRig
    let popover = FakePopover()
    let presenterLog = PresenterLog()
    let presenter: SettingsPresenter
    var clock = Date(timeIntervalSince1970: 1_000)
    private(set) var itemsMade: [FakeStatusItem] = []
    private(set) var menuBar: MenuBarItemController!

    init(storedPercentage: Double? = 50) {
        rig = ControllerRig(storedPercentage: storedPercentage)
        presenter = presenterLog.presenter
        menuBar = MenuBarItemController(
            controller: rig.controller,
            popover: popover,
            settings: presenter,
            makeItem: { [unowned self] in
                let item = FakeStatusItem()
                itemsMade.append(item)
                return item
            },
            now: { [unowned self] in clock }
        )
    }

    var button: NSButton { itemsMade[0].button }

    /// Lets the main-actor work that an observed change schedules run.
    func settle(until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }
}

@MainActor
@Suite("Menu bar item")
struct MenuBarItemControllerTests {
    @Test("the status item is created exactly once, however often it is installed")
    func createdOnce() {
        let rig = MenuBarRig()
        #expect(rig.itemsMade.isEmpty)
        #expect(!rig.menuBar.isInstalled)
        rig.menuBar.install()
        rig.menuBar.install()
        #expect(rig.itemsMade.count == 1)
        #expect(rig.menuBar.isInstalled)
    }

    @Test("a press opens the popover under the button, and the next one closes it")
    func toggleOpensAndCloses() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        rig.menuBar.toggle()
        #expect(rig.popover.isShown)
        #expect(rig.popover.anchors == [rig.button])
        rig.menuBar.toggle()
        #expect(!rig.popover.isShown)
        rig.menuBar.toggle()
        #expect(rig.popover.isShown)
        #expect(rig.popover.showCount == 2)
    }

    @Test("a press before the item is installed does nothing")
    func noPressBeforeInstall() {
        let rig = MenuBarRig()
        rig.menuBar.toggle()
        #expect(!rig.popover.isShown)
    }

    @Test("a dismissal from outside or Esc leaves the popover closed, and a press after it opens it again")
    func outsideDismissal() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        rig.menuBar.toggle()
        rig.popover.dismissFromOutside()
        #expect(!rig.popover.isShown)
        #expect(!rig.menuBar.isPopoverShown)
        rig.clock.addTimeInterval(1)
        rig.menuBar.toggle()
        #expect(rig.popover.isShown)
    }

    @Test("the click that dismissed the popover does not reopen it")
    func clickOnTheButtonWhileOpenDoesNotBounce() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        rig.menuBar.toggle()
        // The mouse-down closes the transient popover; the action follows.
        rig.popover.dismissFromOutside()
        rig.clock.addTimeInterval(MenuBarItemController.dismissalGrace / 2)
        rig.menuBar.toggle()
        #expect(!rig.popover.isShown)
        // The next, separate click opens it.
        rig.menuBar.toggle()
        #expect(rig.popover.isShown)
    }

    @Test("closing with a press is not counted as a dismissal, so the next press opens at once")
    func closeByPressThenOpenImmediately() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        rig.menuBar.toggle()
        rig.menuBar.toggle()
        rig.menuBar.toggle()
        #expect(rig.popover.isShown)
    }

    @Test("showing the popover re-reads the display and the permissions first")
    func willShowRefreshes() {
        let rig = MenuBarRig(storedPercentage: 50)
        rig.menuBar.install()
        rig.rig.display.stubbedCurrentNominalPercentage = 30
        let queriesBefore = rig.rig.permissionsChecker.accessibilityQueryCount
        rig.menuBar.toggle()
        #expect(rig.rig.controller.currentState.percentage == 30)
        #expect(rig.rig.permissionsChecker.accessibilityQueryCount > queriesBefore)
    }

    @Test("opening Settings closes the popover")
    func settingsClosesThePopover() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        rig.menuBar.toggle()
        rig.presenter.show()
        #expect(!rig.popover.isShown)
        #expect(rig.popover.closeReasons == [.settings])
        #expect(rig.presenterLog.events == ["activate", "make window", "front"])
    }

    @Test("a toggle close is recorded as a toggle")
    func toggleReason() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        rig.menuBar.toggle()
        rig.menuBar.toggle()
        #expect(rig.popover.closeReasons == [.toggle])
    }

    @Test("a press right after launch, then another after a non-toggle close, each open the popover and keep it open")
    func pressesAfterNonToggleClose() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        rig.menuBar.toggle()
        #expect(rig.popover.isShown)
        // A close that was not a press: Settings.
        rig.presenter.show()
        #expect(!rig.popover.isShown)
        rig.clock.addTimeInterval(1)
        rig.menuBar.toggle()
        #expect(rig.popover.isShown)
        rig.popover.dismissFromOutside()
        rig.clock.addTimeInterval(1)
        rig.menuBar.toggle()
        #expect(rig.popover.isShown)
        #expect(rig.popover.showCount == 3)
    }

    @Test("every entry path that opens Settings goes through the one presenter")
    func settingsEntryPaths() {
        let rig = MenuBarRig()
        let reveal = AppReveal(settings: rig.presenter)
        rig.presenter.show()
        _ = reveal.handleReopen()
        #expect(rig.presenterLog.made.count == 1)
        #expect(rig.presenterLog.fronted.count == 2)
    }

    @Test("the button's image and accessibility label are set at install and follow the level")
    func imageAndLabelFollowState() async throws {
        let rig = MenuBarRig(storedPercentage: 40)
        rig.menuBar.install()
        let button = rig.button
        #expect(button.accessibilityLabel() == "BrightBoi, brightness 40 percent")
        let image = try #require(button.image)
        #expect(image.isTemplate)
        #expect(image.accessibilityDescription == "BrightBoi, brightness 40 percent")
        let before = try #require(image.tiffRepresentation)

        rig.rig.controller.setPercentage(120)
        await rig.settle { button.accessibilityLabel()?.contains("120") == true }
        #expect(button.accessibilityLabel() == "BrightBoi, brightness 120 percent, boosted")
        #expect(button.image?.accessibilityDescription == "BrightBoi, brightness 120 percent, boosted")
        #expect(button.image?.tiffRepresentation != before)

        rig.rig.controller.setPercentage(20)
        await rig.settle { button.accessibilityLabel()?.contains("20 percent") == true && button.accessibilityLabel()?.contains("boosted") == false }
        #expect(button.accessibilityLabel() == "BrightBoi, brightness 20 percent")
    }

    @Test("the label never reads as the symbol's own 'Increase Brightness'")
    func noIncreaseBrightness() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        let spoken = [rig.button.accessibilityLabel(), rig.button.image?.accessibilityDescription].compactMap { $0 }
        #expect(!spoken.isEmpty)
        #expect(spoken.allSatisfy { !$0.localizedCaseInsensitiveContains("increase") })
    }

    @Test("the accessibility press action on the button opens the popover, like a click")
    func axPressOpensThePopover() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        // The return value is not reliable for a button outside a window;
        // what matters is that the press reaches the action.
        _ = rig.button.accessibilityPerformPress()
        #expect(rig.popover.isShown)
        _ = rig.button.accessibilityPerformPress()
        #expect(!rig.popover.isShown)
    }

    @Test("the button announces a press action to assistive clients", accessibilityAvailable)
    func buttonListsThePressAction() {
        AXSession.activate()
        let rig = MenuBarRig()
        rig.menuBar.install()
        // In a window far off every display: a button reports accessibility
        // only once it is on screen, as the harness's other views do.
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 40, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(rig.button)
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let tree = AXTree(root: window.contentView!)
        let node = tree.node(named: "BrightBoi, brightness 50 percent", role: .button)
        #expect(node?.actions.contains(NSAccessibility.Action.press.rawValue) == true, "\(tree.dump)")
    }

    @Test("a press after a close that has begun but not finished does not reopen the popover")
    func pressDuringTheClosingAnimation() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        rig.menuBar.toggle()
        // The user's click closes it: willClose arrives, the popover still
        // reads as shown for the length of the animation, and the press lands.
        rig.popover.beginDismissal()
        rig.clock.addTimeInterval(0.05)
        rig.menuBar.toggle()
        rig.popover.finishDismissal()
        #expect(!rig.popover.isShown)
    }

    @Test("the status item is skipped, not faked, when the status bar gives no button")
    func missingItem() {
        let rig = MenuBarRig()
        let menuBar = MenuBarItemController(
            controller: rig.rig.controller, popover: rig.popover, settings: rig.presenter,
            makeItem: { nil }
        )
        menuBar.install()
        #expect(!menuBar.isInstalled)
        menuBar.toggle()
        #expect(!rig.popover.isShown)
    }

    @Test("the button has a target and an action, which AXPress needs")
    func buttonHasTargetAndAction() {
        let rig = MenuBarRig()
        rig.menuBar.install()
        #expect(rig.button.target != nil)
        #expect(rig.button.action != nil)
        #expect(rig.button.imagePosition == .imageOnly)
    }
}

@MainActor
@Suite("System popover")
struct SystemPopoverTests {
    @Test("it does not close with the app, since dismissal is explicit, and hosts the content")
    func configuration() {
        let content = NSViewController()
        let popover = SystemPopover(content: content, monitors: FakeMonitors())
        #expect(popover.popover.behavior == .applicationDefined)
        #expect(popover.popover.contentViewController === content)
        #expect(!popover.isShown)
    }

    @Test("the reason a close was asked for is recorded, and other closes read as other")
    func closeReasons() {
        let popover = SystemPopover(content: NSViewController(), monitors: FakeMonitors())
        popover.close(reason: .escape)
        popover.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        #expect(popover.lastCloseReason == .escape)
        popover.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        #expect(popover.lastCloseReason == .other)
    }

    @Test("the popover's delegate reports the start of closing and is asked before showing")
    func delegateForwards() {
        let popover = SystemPopover(content: NSViewController(), monitors: FakeMonitors())
        var events: [String] = []
        popover.willShow = { events.append("will show") }
        popover.willClose = { events.append("will close") }
        popover.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        popover.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        #expect(events == ["will show", "will close"])
    }
}

extension SystemPopoverTests {
    @Test("showing installs the dismissal monitors and closing removes them, cycle after cycle")
    func monitorsFollowShowAndClose() {
        let monitors = FakeMonitors()
        let popover = SystemPopover(content: NSViewController(), monitors: monitors)
        for cycle in 1...2 {
            popover.popoverWillShow(Notification(name: NSPopover.willShowNotification))
            #expect(monitors.live == 3)
            #expect(monitors.installed == 3 * cycle)
            popover.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
            #expect(monitors.live == 0)
            #expect(monitors.removed == 3 * cycle)
        }
    }
}

/// Counts monitors instead of installing them, and lets a test deliver events.
@MainActor
final class FakeMonitors: EventMonitoring {
    private(set) var installed = 0
    private(set) var removed = 0
    private var locals: [(id: Int, mask: NSEvent.EventTypeMask, handler: (NSEvent) -> NSEvent?)] = []
    private var globals: [(id: Int, mask: NSEvent.EventTypeMask, handler: (NSEvent) -> Void)] = []
    private var nextID = 0

    var live: Int { locals.count + globals.count }

    func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        installed += 1; nextID += 1
        locals.append((nextID, mask, handler))
        return nextID
    }

    func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? {
        installed += 1; nextID += 1
        globals.append((nextID, mask, handler))
        return nextID
    }

    func remove(_ token: Any) {
        guard let id = token as? Int else { return }
        removed += 1
        locals.removeAll { $0.id == id }
        globals.removeAll { $0.id == id }
    }

    /// A mouse down at a screen point, seen by the local and the global monitors.
    func mouseDown(at point: NSPoint, type: NSEvent.EventType = .leftMouseDown) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        let mask = NSEvent.EventTypeMask(rawValue: 1 << type.rawValue)
        for local in locals where local.mask.contains(mask) { _ = local.handler(event) }
        for global in globals where global.mask.contains(mask) { global.handler(event) }
    }

    /// A key press; returns whether the local monitors let it through.
    @discardableResult
    func keyDown(code: UInt16) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code
        )!
        var passed = true
        for local in locals where local.mask.contains(.keyDown) {
            if local.handler(event) == nil { passed = false }
        }
        return passed
    }
}

@MainActor
@Suite("Popover dismissal")
struct PopoverDismissalTests {
    let popoverFrame = NSRect(x: 100, y: 100, width: 300, height: 300)
    let buttonFrame = NSRect(x: 500, y: 900, width: 30, height: 24)

    private func make(screens: @escaping @MainActor () -> [ScreenSnapshot] = { [] }) -> (PopoverDismissal, FakeMonitors, NotificationCenter, Counter) {
        let monitors = FakeMonitors()
        let center = NotificationCenter()
        let closes = Counter()
        let frames = [popoverFrame, buttonFrame]
        let dismissal = PopoverDismissal(
            monitors: monitors, notifications: center,
            insideFrames: { frames }, popoverWindow: { nil },
            screens: screens,
            close: { closes.count += 1; closes.reasons.append($0) }
        )
        return (dismissal, monitors, center, closes)
    }

    final class Counter {
        var count = 0
        var reasons: [PopoverCloseReason] = []
    }

    final class Screens {
        var list = [
            ScreenSnapshot(displayID: 1, frame: NSRect(x: 0, y: 0, width: 1728, height: 1117)),
            ScreenSnapshot(displayID: 2, frame: NSRect(x: 1728, y: 0, width: 2560, height: 1440)),
        ]
    }

    @Test("monitors are installed on start and removed once on stop, and none are left")
    func installAndRemove() {
        let (dismissal, monitors, _, _) = make()
        #expect(monitors.live == 0)
        dismissal.start()
        dismissal.start()
        #expect(monitors.installed == 3)
        #expect(monitors.live == 3)
        dismissal.stop()
        dismissal.stop()
        #expect(monitors.removed == 3)
        #expect(monitors.live == 0)
        #expect(!dismissal.isActive)
    }

    @Test("a mouse down outside closes it, for left, right and other buttons")
    func outsideMouseDownCloses() {
        let (dismissal, monitors, _, closes) = make()
        dismissal.start()
        monitors.mouseDown(at: NSPoint(x: 10, y: 10))
        monitors.mouseDown(at: NSPoint(x: 10, y: 10), type: .rightMouseDown)
        monitors.mouseDown(at: NSPoint(x: 10, y: 10), type: .otherMouseDown)
        // Local and global monitors both see a click in this fake.
        #expect(closes.count == 6)
    }

    @Test("a mouse down inside the popover or on the status button does not close it")
    func insideMouseDownStaysOpen() {
        let (dismissal, monitors, _, closes) = make()
        dismissal.start()
        monitors.mouseDown(at: NSPoint(x: 200, y: 200))
        monitors.mouseDown(at: NSPoint(x: 510, y: 910))
        #expect(closes.count == 0)
    }

    @Test("Esc closes it and is consumed; other keys pass through")
    func escape() {
        let (dismissal, monitors, _, closes) = make()
        dismissal.start()
        #expect(monitors.keyDown(code: 0))
        #expect(closes.count == 0)
        #expect(!monitors.keyDown(code: 53))
        #expect(closes.count == 1)
    }

    @Test("the app terminating closes it, and nothing does once it is stopped")
    func termination() {
        let (dismissal, _, center, closes) = make()
        dismissal.start()
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(closes.reasons == [.terminate])
        dismissal.stop()
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(closes.count == 1)
    }

    @Test("a screen-parameters notification with the same screens does not close it")
    func unchangedScreensStayOpen() {
        let screens = Screens()
        let (dismissal, _, center, closes) = make(screens: { screens.list })
        dismissal.start()
        // Boost engaging, the overlay's EDR headroom settling and the app
        // activating all post this with nothing moved.
        for _ in 1...3 { center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil) }
        #expect(closes.count == 0)
    }

    @Test("a screen added, removed, moved or resized closes it, once, with that reason")
    func changedScreensClose() {
        let changes: [(String, ([ScreenSnapshot]) -> [ScreenSnapshot])] = [
            ("removed", { Array($0.dropLast()) }),
            ("added", { $0 + [ScreenSnapshot(displayID: 3, frame: NSRect(x: 4288, y: 0, width: 1920, height: 1080))] }),
            ("moved", { var l = $0; l[1].frame.origin.x += 100; return l }),
            ("resized", { var l = $0; l[0].frame.size.width = 1512; return l }),
            ("swapped", { var l = $0; l[0].displayID = 9; return l }),
        ]
        for (name, change) in changes {
            let screens = Screens()
            let (dismissal, _, center, closes) = make(screens: { screens.list })
            dismissal.start()
            screens.list = change(screens.list)
            center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            #expect(closes.reasons == [.screenChange], "\(name)")
        }
    }

    @Test("the screens are read when it starts, so a change before showing is not a change")
    func baselineIsTakenAtStart() {
        let screens = Screens()
        let (dismissal, _, center, closes) = make(screens: { screens.list })
        screens.list.removeLast()
        dismissal.start()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(closes.count == 0)
    }

    @Test("closing for a mouse down and for Esc carry their reasons")
    func reasons() {
        let (dismissal, monitors, _, closes) = make()
        dismissal.start()
        monitors.mouseDown(at: NSPoint(x: 10, y: 10))
        monitors.keyDown(code: 53)
        #expect(closes.reasons.contains(.outsideClick))
        #expect(closes.reasons.last == .escape)
    }

    @Test("the app resigning or deactivating does not close it")
    func resignDoesNotClose() {
        let (dismissal, _, center, closes) = make()
        dismissal.start()
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(closes.count == 0)
    }
}
