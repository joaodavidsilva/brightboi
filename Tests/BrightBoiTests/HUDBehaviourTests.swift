import AppKit
import Testing
@testable import BrightBoi

/// Drives `BrightnessHUDController` with a manual clock, a recorded animation
/// and a recorded accessibility poster, so the fade, the focus rules and the
/// announcement can be asserted without a screen, real time or VoiceOver. The
/// panel itself is real but sits far off every screen, and every test ends
/// with it ordered out.
@MainActor
final class HUDRig {
    struct Timer {
        var delay: TimeInterval
        var work: @MainActor () -> Void
        var cancelled = false
    }
    struct Animation {
        var alpha: CGFloat
        var duration: TimeInterval
        var completion: (@MainActor () -> Void)?
    }
    struct Post {
        var element: Any
        var notification: NSAccessibility.Notification
        var userInfo: [NSAccessibility.NotificationUserInfoKey: Any]
    }

    var origin: CGPoint? = CGPoint(x: -30_000, y: -30_000)
    var reduceMotion = false
    var style: HUDStyle = .bezel
    private(set) var timers: [Timer] = []
    private(set) var animations: [Animation] = []
    private(set) var posts: [Post] = []
    private(set) var controller: BrightnessHUDController!

    init(autoDismissDelay: TimeInterval = 1) {
        let environment = HUDEnvironment(
            origin: { [unowned self] _, _ in origin },
            style: { [unowned self] in style },
            reduceMotion: { [unowned self] in reduceMotion },
            schedule: { [unowned self] delay, work in
                timers.append(Timer(delay: delay, work: work))
                let index = timers.count - 1
                return { [unowned self] in timers[index].cancelled = true }
            },
            animateAlpha: { [unowned self] _, alpha, duration, completion in
                animations.append(Animation(alpha: alpha, duration: duration, completion: completion))
            },
            postAccessibility: { [unowned self] element, notification, userInfo in
                posts.append(Post(element: element, notification: notification, userInfo: userInfo))
            }
        )
        controller = BrightnessHUDController(autoDismissDelay: autoDismissDelay, environment: environment)
    }

    var panel: NSPanel { controller.panel }
    func press(_ percentage: Double = 120) {
        controller.present(state: ControllerRig(storedPercentage: percentage).controller.currentState)
    }

    /// A press in the Boost paused state (Invert Colors on).
    func pressPaused(_ percentage: Double = 150) {
        var state = ControllerRig(storedPercentage: percentage).controller.currentState
        state.isBoostPaused = true
        controller.present(state: state)
    }

    /// Fires the timers that are still live and have this `delay`, as if that
    /// much time had passed.
    func fireTimers(delay: TimeInterval) {
        for index in timers.indices where timers[index].delay == delay && !timers[index].cancelled {
            timers[index].cancelled = true
            timers[index].work()
        }
    }

    func finishAnimation(at index: Int) {
        let completion = animations[index].completion
        animations[index].completion = nil
        completion?()
    }

    var liveTimers: [Timer] { timers.filter { !$0.cancelled } }

    func tearDown() { controller.hideImmediately() }
}

@MainActor
@Suite("HUD behaviour", .serialized)
struct HUDBehaviourTests {
    // MARK: Fade

    @Test("a press from hidden starts transparent and fades in over 0.12 s")
    func fadesIn() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.press()
        #expect(rig.panel.alphaValue == 0)
        #expect(rig.panel.isVisible)
        #expect(rig.animations.map(\.alpha) == [1])
        #expect(rig.animations.map(\.duration) == [BrightnessHUDController.fadeInDuration])
        #expect(BrightnessHUDController.fadeInDuration == 0.12)
    }

    @Test("holding a key does not re-fade: later presses snap to opaque with no duration")
    func heldKeyDoesNotRefade() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        for _ in 0..<10 { rig.press() }
        #expect(rig.animations.count == 10)
        #expect(rig.animations.first?.duration == BrightnessHUDController.fadeInDuration)
        #expect(rig.animations.dropFirst().allSatisfy { $0.alpha == 1 && $0.duration == 0 })
    }

    @Test("the HUD fades out over 0.35 s after the last press, then orders out")
    func fadesOutAndOrdersOut() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.press()
        #expect(rig.liveTimers.filter { $0.delay == 1 }.count == 1)
        rig.fireTimers(delay: 1)
        let fadeOut = rig.animations.last
        #expect(fadeOut?.alpha == 0)
        #expect(fadeOut?.duration == BrightnessHUDController.fadeOutDuration)
        #expect(BrightnessHUDController.fadeOutDuration == 0.35)
        #expect(rig.panel.isVisible)
        rig.finishAnimation(at: rig.animations.count - 1)
        #expect(!rig.panel.isVisible)
    }

    @Test("every press pushes the dismissal back, so only the last one counts")
    func dismissalFollowsTheLastPress() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.press()
        rig.press()
        rig.press()
        #expect(rig.liveTimers.filter { $0.delay == 1 }.count == 1)
    }

    @Test("a press during the fade-out brings the HUD back and the stale fade does not order it out")
    func pressDuringFadeOut() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.press()
        rig.fireTimers(delay: 1)
        let fadeOutIndex = rig.animations.count - 1
        rig.press()
        #expect(rig.animations.last?.alpha == 1)
        #expect(rig.animations.last?.duration == 0)
        rig.finishAnimation(at: fadeOutIndex)
        #expect(rig.panel.isVisible)
        // The press scheduled a fresh dismissal, which still works.
        rig.fireTimers(delay: 1)
        rig.finishAnimation(at: rig.animations.count - 1)
        #expect(!rig.panel.isVisible)
    }

    @Test("with Reduce Motion on, the HUD appears and disappears with no fade")
    func reduceMotion() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.reduceMotion = true
        rig.press()
        rig.fireTimers(delay: 1)
        #expect(rig.animations.map(\.duration) == [0, 0])
    }

    @Test("Reduce Motion is read on every press, so turning it on takes effect at once")
    func reduceMotionIsLive() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.press()
        rig.reduceMotion = true
        rig.fireTimers(delay: 1)
        #expect(rig.animations.last?.duration == 0)
    }

    @Test("nothing happens while the built-in display is not active")
    func noBuiltInNoHUD() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.origin = nil
        rig.press()
        #expect(!rig.panel.isVisible)
        #expect(rig.animations.isEmpty)
        #expect(rig.timers.isEmpty)
        #expect(rig.posts.isEmpty)
    }

    /// The real timer and the real animation, with only the screen position,
    /// Reduce Motion and the accessibility post replaced. Waits by suspending,
    /// which is what lets the main queue run them.
    @Test("the real fade-out ends by ordering the panel out")
    func realFadeOutOrdersOut() async throws {
        var environment = HUDEnvironment.live
        environment.origin = { _, _ in CGPoint(x: -30_000, y: -30_000) }
        environment.reduceMotion = { false }
        environment.postAccessibility = { _, _, _ in }
        let controller = BrightnessHUDController(autoDismissDelay: 0.05, environment: environment)
        defer { controller.hideImmediately() }
        controller.present(state: ControllerRig(storedPercentage: 50).controller.currentState)
        #expect(controller.panel.isVisible)
        var waited = 0
        while controller.panel.isVisible, waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        // How long the fade really takes is not asserted: an animation on a
        // window that is nowhere near a screen may run at any speed. The
        // fade's length is asserted on the durations the controller asks for.
        #expect(!controller.panel.isVisible)
        #expect(controller.panel.alphaValue == 0)
    }

    // MARK: Focus

    @Test("the panel never takes focus and never reacts to the mouse")
    func neverTakesFocus() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.press()
        let panel = rig.panel
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isKeyWindow)
        #expect(!panel.isMainWindow)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.ignoresMouseEvents)
        #expect(NSApplication.shared.keyWindow !== panel)
    }

    @Test("the panel floats over other apps, including full-screen ones, on every Space")
    func floatsOverEverything() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        #expect(rig.panel.level == .statusBar)
        let behaviour = rig.panel.collectionBehavior
        #expect(behaviour.contains(.canJoinAllSpaces))
        #expect(behaviour.contains(.fullScreenAuxiliary))
    }

    // MARK: Announcement

    @Test("a burst of presses is announced once, with the last value")
    func announcesOncePerBurst() throws {
        let rig = HUDRig()
        defer { rig.tearDown() }
        for percentage in [100.0, 105, 110, 115, 120] { rig.press(percentage) }
        #expect(rig.posts.isEmpty)
        #expect(rig.liveTimers.filter { $0.delay == BrightnessHUDController.announcementDebounce }.count == 1)
        rig.fireTimers(delay: BrightnessHUDController.announcementDebounce)
        let post = try #require(rig.posts.first)
        #expect(rig.posts.count == 1)
        #expect(post.userInfo[.announcement] as? String == "Brightness 120 percent, boosted")
    }

    @Test("two separate presses are announced separately")
    func separateBurstsAreEachAnnounced() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.press(60)
        rig.fireTimers(delay: BrightnessHUDController.announcementDebounce)
        rig.press(65)
        rig.fireTimers(delay: BrightnessHUDController.announcementDebounce)
        #expect(rig.posts.compactMap { $0.userInfo[.announcement] as? String }
            == ["Brightness 60 percent", "Brightness 65 percent"])
    }

    @Test("the announcement is posted for the application at high priority, not for a window")
    func announcementTargetsTheApplication() throws {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.press(50)
        rig.fireTimers(delay: BrightnessHUDController.announcementDebounce)
        let post = try #require(rig.posts.first)
        #expect(post.notification == .announcementRequested)
        #expect(post.element as? NSApplication === NSApplication.shared)
        #expect(!(post.element is NSWindow))
        #expect(post.userInfo[.priority] as? Int == NSAccessibilityPriorityLevel.high.rawValue)
        // Nothing about the post depends on BrightBoi or its HUD being key,
        // active or even on screen: the panel is not key.
        #expect(!rig.panel.isKeyWindow)
    }

    @Test("the announcement's payload is exactly the text and the priority")
    func userInfo() {
        let info = BrightnessHUDController.announcementUserInfo(text: "Brightness 10 percent")
        #expect(info.count == 2)
        #expect(info[.announcement] as? String == "Brightness 10 percent")
        #expect(info[.priority] as? Int == NSAccessibilityPriorityLevel.high.rawValue)
    }

    @Test("the HUD view hides itself from accessibility, since the announcement carries the level", accessibilityAvailable)
    func hudViewIsHidden() {
        let host = OffscreenHost(BrightnessHUDView(state: ControllerRig(storedPercentage: 80).controller.currentState))
        defer { OffscreenWindows.closeAll() }
        #expect(host.tree.nodes.isEmpty, "HUD exposes: \(host.tree.dump)")
    }
}
