import AppKit
import SwiftUI
import Testing
@testable import BrightBoi

/// Records what a `SettingsPresenter` does, in order, without activating the
/// real app, sending anything down the real responder chain or ordering a real
/// window forward.
@MainActor
final class PresenterLog {
    private(set) var events: [String] = []
    private(set) var fronted: [NSWindow] = []
    var responderChainAnswer = true

    func record(_ event: String) { events.append(event) }

    var presenter: SettingsPresenter { presenter(now: Date.init) }

    func presenter(now: @escaping () -> Date) -> SettingsPresenter {
        SettingsPresenter(
            activate: { [self] in record("activate") },
            openThroughResponderChain: { [self] in
                record("responder chain")
                return responderChainAnswer
            },
            front: { [self] window in
                record("front")
                fronted.append(window)
            },
            now: now
        )
    }
}

extension SettingsPresenter {
    /// A presenter that does nothing at all, for views under test.
    @MainActor
    static func inert() -> SettingsPresenter {
        SettingsPresenter(activate: {}, openThroughResponderChain: { true }, front: { _ in })
    }
}

@MainActor
private func offscreenWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
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
    @Test("the app is activated before Settings opens, and the window is fronted after")
    func orderIsActivateOpenFront() {
        let log = PresenterLog()
        let presenter = log.presenter
        let window = offscreenWindow()
        presenter.register(window: window)
        presenter.register(sceneOpener: { log.record("open") })
        presenter.show()
        #expect(log.events == ["activate", "open", "front"])
        #expect(log.fronted == [window])
    }

    @Test("a caller's own opener wins over the registered one")
    func callerOpenerWins() {
        let log = PresenterLog()
        let presenter = log.presenter
        presenter.register(sceneOpener: { log.record("registered") })
        presenter.show(using: { log.record("popover") })
        #expect(log.events.prefix(2) == ["activate", "popover"])
    }

    @Test("with no opener registered the request goes down the responder chain, after activating")
    func fallsBackToTheResponderChain() {
        let log = PresenterLog()
        log.presenter.show()
        #expect(log.events.prefix(2) == ["activate", "responder chain"])
    }

    @Test("a window that reports in after the request is fronted once, when it arrives")
    func frontsALateWindow() {
        let log = PresenterLog()
        let presenter = log.presenter
        presenter.register(sceneOpener: { log.record("open") })
        presenter.show()
        #expect(log.events == ["activate", "open"])
        let window = offscreenWindow()
        presenter.register(window: window)
        presenter.register(window: window)
        #expect(log.events == ["activate", "open", "front"])
        #expect(log.fronted == [window])
    }

    @Test("a window that reports in long after a request that produced none is left alone")
    func ignoresAStaleRequest() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let log = PresenterLog()
        let presenter = log.presenter(now: { clock })
        presenter.show()
        clock.addTimeInterval(SettingsPresenter.lateWindowGrace + 1)
        presenter.register(window: offscreenWindow())
        #expect(log.fronted.isEmpty)
    }

    @Test("each request activates, opens and fronts exactly once")
    func onceEach() {
        let log = PresenterLog()
        let presenter = log.presenter
        presenter.register(window: offscreenWindow())
        presenter.register(sceneOpener: { log.record("open") })
        presenter.show()
        presenter.show()
        #expect(log.events == ["activate", "open", "front", "activate", "open", "front"])
    }

    @Test("a window's content tells the presenter which window it is in")
    func windowReaderRegisters() {
        let log = PresenterLog()
        let presenter = log.presenter
        let host = OffscreenHost(Text("Settings").registersAsSettingsWindow(presenter))
        defer { OffscreenWindows.closeAll() }
        presenter.register(sceneOpener: {})
        presenter.show()
        #expect(log.fronted == [host.window])
    }

    @Test("the menu bar label registers the open action, so a request that is not from the popover reaches it")
    func labelRegistersTheOpener() {
        let rig = ControllerRig()
        let presenter = SettingsPresenter.inert()
        #expect(!presenter.hasSceneOpener)
        _ = OffscreenHost(BrightnessMenuBarIcon(controller: rig.controller, settings: presenter))
        defer { OffscreenWindows.closeAll() }
        #expect(presenter.hasSceneOpener)
    }
}

@MainActor
@Suite("Reopen and second launch", .serialized)
struct AppRevealTests {
    private func reveal(_ log: PresenterLog, onboardingShowing: Bool = false) -> AppReveal {
        let reveal = AppReveal(settings: log.presenter)
        reveal.settings.register(sceneOpener: { log.record("open") })
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
        #expect(log.events == ["activate", "open"])
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
        #expect(log.events == ["activate", "open"])
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
        reveal.settings.register(sceneOpener: { log.record("open") })
        _ = reveal.handleReopen()
        clock.addTimeInterval(0.1)
        reveal.reveal()
        #expect(log.events == ["activate", "open"])
        clock.addTimeInterval(AppReveal.coalesceWindow)
        reveal.reveal()
        #expect(log.events == ["activate", "open", "activate", "open"])
    }

    @Test("the hand-off uses the system-wide notification center")
    func usesTheDistributedCenter() {
        #expect(SingleInstanceGuard.systemCenter is DistributedNotificationCenter)
    }
}
