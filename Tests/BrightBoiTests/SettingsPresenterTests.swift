import AppKit
import SwiftUI
import Testing
@testable import BrightBoi

/// Records what a `SettingsPresenter` does, in order, without activating the
/// real app or ordering a real window forward. The windows it makes are plain
/// borderless windows that are never shown.
@MainActor
final class PresenterLog {
    private(set) var events: [String] = []
    private(set) var fronted: [NSWindow] = []
    private(set) var made: [NSWindow] = []
    /// Stands in for the default center, so a test can close a window.
    let center = NotificationCenter()

    func record(_ event: String) { events.append(event) }

    var presenter: SettingsPresenter {
        SettingsPresenter(
            makeWindow: { [self] in
                record("make window")
                let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                made.append(window)
                return window
            },
            activate: { [self] in record("activate") },
            front: { [self] window in
                record("front")
                fronted.append(window)
            },
            notifications: center
        )
    }

    /// What closing the window posts.
    func close(_ window: NSWindow) {
        center.post(name: NSWindow.willCloseNotification, object: window)
    }
}

extension SettingsPresenter {
    /// A presenter that does nothing at all, for views under test.
    @MainActor
    static func inert() -> SettingsPresenter {
        SettingsPresenter(makeWindow: { NSWindow() }, activate: {}, front: { _ in })
    }
}

/// Runs the main run loop until `condition` holds or `seconds` pass.
@MainActor
func spinUntil(_ seconds: TimeInterval = 2, _ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}

@MainActor
@Suite("Settings presenter")
struct SettingsPresenterTests {
    @Test("the app is activated, the window made, and then it is fronted, in that order")
    func orderIsActivateMakeFront() {
        let log = PresenterLog()
        log.presenter.show()
        #expect(log.events == ["activate", "make window", "front"])
        #expect(log.fronted == log.made)
    }

    @Test("the popover is put away before anything else happens")
    func popoverClosesFirst() {
        let log = PresenterLog()
        let presenter = log.presenter
        presenter.willShow = { log.record("close popover") }
        presenter.show()
        #expect(log.events == ["close popover", "activate", "make window", "front"])
    }

    @Test("opening twice yields one window, fronted both times")
    func oneWindow() {
        let log = PresenterLog()
        let presenter = log.presenter
        presenter.show()
        presenter.show()
        #expect(log.made.count == 1)
        #expect(log.fronted == [log.made[0], log.made[0]])
        #expect(log.events == ["activate", "make window", "front", "activate", "front"])
        #expect(presenter.window === log.made[0])
    }

    @Test("a window that was closed is released, and the next request makes a new one")
    func closedWindowIsReleased() {
        let log = PresenterLog()
        let presenter = log.presenter
        presenter.show()
        log.close(log.made[0])
        #expect(presenter.window == nil)
        presenter.show()
        #expect(log.made.count == 2)
        #expect(presenter.window === log.made[1])
    }

    @Test("another window closing does not release the Settings window")
    func otherWindowClosing() {
        let log = PresenterLog()
        let presenter = log.presenter
        presenter.show()
        log.close(NSWindow())
        #expect(presenter.window === log.made[0])
    }

    @Test("the real window is titled, closable, not resizable or minimizable, and hosts SettingsView")
    func realWindowHostsSettingsView() {
        let rig = ControllerRig()
        let window = SettingsWindow.make(
            controller: rig.controller, permissions: rig.permissions, onShowSupport: {}, updates: nil
        )
        defer { window.close() }
        #expect(window.title == SettingsWindow.title)
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(!window.styleMask.contains(.resizable))
        #expect(!window.isReleasedWhenClosed)
        #expect(window.contentViewController is NSHostingController<SettingsView>)
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.contentView?.frame.width == 480)
        #expect((window.contentView?.frame.height ?? 0) > 0)
        #expect(!window.isVisible)
    }
}

@MainActor
@Suite("Reopen and second launch", .serialized)
struct AppRevealTests {
    private func reveal(_ log: PresenterLog, onboardingShowing: Bool = false) -> AppReveal {
        let reveal = AppReveal(settings: log.presenter)
        reveal.bringOnboardingForward = {
            if onboardingShowing { log.record("onboarding") }
            return onboardingShowing
        }
        return reveal
    }

    @Test("a Dock or Finder reopen opens Settings once, in front, and returns false")
    func reopenOpensSettings() {
        let log = PresenterLog()
        let handled = reveal(log).handleReopen()
        #expect(handled == false)
        #expect(log.events == ["activate", "make window", "front"])
    }

    @Test("a reopen while onboarding is up brings onboarding forward instead of opening Settings")
    func reopenPrefersOnboarding() {
        let log = PresenterLog()
        #expect(reveal(log, onboardingShowing: true).handleReopen() == false)
        #expect(log.events == ["onboarding"])
    }

    @Test("a second launch opens Settings once, through the same path as a reopen")
    func secondLaunchOpensSettings() {
        let log = PresenterLog()
        let center = NotificationCenter()
        let reveal = reveal(log)
        let observer = reveal.observeSecondLaunch(center: center)
        defer { center.removeObserver(observer) }
        SingleInstanceGuard.revealRunningCopy(center: center)
        spinUntil { log.events.count >= 2 }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        #expect(log.events == ["activate", "make window", "front"])
    }

    @Test("a second launch while onboarding is up brings onboarding forward")
    func secondLaunchPrefersOnboarding() {
        let log = PresenterLog()
        let center = NotificationCenter()
        let reveal = reveal(log, onboardingShowing: true)
        let observer = reveal.observeSecondLaunch(center: center)
        defer { center.removeObserver(observer) }
        SingleInstanceGuard.revealRunningCopy(center: center)
        spinUntil { !log.events.isEmpty }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        #expect(log.events == ["onboarding"])
    }

    @Test("a reopen and a second launch from one user action open Settings once")
    func bothPathsCoalesce() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let log = PresenterLog()
        let reveal = AppReveal(settings: log.presenter, now: { clock })
        _ = reveal.handleReopen()
        clock.addTimeInterval(0.1)
        reveal.reveal()
        #expect(log.events == ["activate", "make window", "front"])
        clock.addTimeInterval(AppReveal.coalesceWindow)
        reveal.reveal()
        #expect(log.events == ["activate", "make window", "front", "activate", "front"])
    }

    @Test("the hand-off uses the system-wide notification center")
    func usesTheDistributedCenter() {
        #expect(SingleInstanceGuard.systemCenter is DistributedNotificationCenter)
    }
}
