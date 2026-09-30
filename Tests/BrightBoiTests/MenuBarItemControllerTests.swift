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

    func show(relativeTo button: NSButton) {
        willShow?()
        isShown = true
        showCount += 1
        anchors.append(button)
    }

    func close() {
        guard isShown else { return }
        willClose?()
        isShown = false
    }

    func dismissFromOutside() { close() }

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
        #expect(rig.presenterLog.events.prefix(2) == ["activate", "responder chain"])
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
    @Test("it is transient, so a click outside and Esc close it, and hosts the content")
    func configuration() {
        let content = NSViewController()
        let popover = SystemPopover(content: content)
        #expect(popover.popover.behavior == .transient)
        #expect(popover.popover.contentViewController === content)
        #expect(!popover.isShown)
    }

    @Test("the popover's delegate reports the start of closing and is asked before showing")
    func delegateForwards() {
        let popover = SystemPopover(content: NSViewController())
        var events: [String] = []
        popover.willShow = { events.append("will show") }
        popover.willClose = { events.append("will close") }
        popover.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        popover.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        #expect(events == ["will show", "will close"])
    }
}
