import AppKit
import Testing
@testable import BrightBoi

@Suite("HUD meter")
struct HUDMeterTests {
    @Test("a segment fills in proportion to the level inside it", arguments: [
        (6, 80.0, 0.4), (6, 85.0, 0.8), (8, 105.0, 0.4), (0, 0.0, 0.0), (0, 5.0, 0.4),
        (15, 200.0, 1.0), (3, 100.0, 1.0), (9, 100.0, 0.0)
    ])
    func fill(index: Int, percentage: Double, expected: Double) {
        let fill = BrightnessHUDView.segmentFill(index: index, percentage: percentage, span: 12.5)
        #expect(abs(fill - expected) < 0.0001)
    }

    @Test("a segment is locked once it starts at or past the ceiling")
    func locked() {
        #expect(!BrightnessHUDView.isLocked(index: 12, span: 12.5, ceiling: 155))
        #expect(BrightnessHUDView.isLocked(index: 13, span: 12.5, ceiling: 155))
        #expect(BrightnessHUDView.isLocked(index: 12, span: 12.5, ceiling: 150))
        #expect(!BrightnessHUDView.isLocked(index: 15, span: 12.5, ceiling: 200))
    }

    @Test("each press of 5% changes some segment until the ceiling")
    func everyPressMoves() {
        let span = BrightnessHUDView.segmentSpan(supportsBoost: true)
        func fills(_ p: Double) -> [Double] { (0..<16).map { BrightnessHUDView.segmentFill(index: $0, percentage: p, span: span) } }
        for step in 0..<40 {
            #expect(fills(Double(step) * 5) != fills(Double(step + 1) * 5))
        }
    }

    @Test("segment span follows the reachable range")
    func span() {
        #expect(BrightnessHUDView.segmentSpan(supportsBoost: true) == 12.5)
        #expect(BrightnessHUDView.segmentSpan(supportsBoost: false) == 12.5)
    }

    @Test("the readout rounds to a whole percent")
    func readout() {
        #expect(BrightnessHUDView.readout(percentage: 0) == "0%")
        #expect(BrightnessHUDView.readout(percentage: 104.6) == "105%")
    }
}

@MainActor
@Suite("HUD controller")
struct HUDControllerTests {
    private let panel = CGSize(width: 190, height: 190)

    @Test("the built-in screen wins even when listed second")
    func builtInListedSecond() {
        let origin = BrightnessHUDController.hudOrigin(
            panelSize: panel,
            screens: [(id: 7, visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1400)),
                      (id: 1, visibleFrame: CGRect(x: 2560, y: 0, width: 1512, height: 944))],
            isBuiltin: { $0 == 1 }
        )
        #expect(origin != nil)
        #expect(origin?.x == CGFloat(3221))
        #expect(origin.map { abs($0.y - 944 * 0.18) < 0.0001 } == true)
    }

    @Test("the origin follows the usable area, not the full frame")
    func usesVisibleFrame() {
        let origin = BrightnessHUDController.hudOrigin(
            panelSize: panel,
            screens: [(id: 1, visibleFrame: CGRect(x: 0, y: 70, width: 1000, height: 800))],
            isBuiltin: { _ in true }
        )
        #expect(origin == CGPoint(x: 405, y: 70 + 800 * 0.18))
    }

    @Test("no built-in screen returns nil")
    func noBuiltIn() {
        let origin = BrightnessHUDController.hudOrigin(
            panelSize: panel,
            screens: [(id: 7, visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1400))],
            isBuiltin: { _ in false }
        )
        #expect(origin == nil)
        #expect(BrightnessHUDController.hudOrigin(panelSize: panel, screens: [], isBuiltin: { _ in true }) == nil)
    }

    @Test("the announcement names the level, Boost and the ends of the range")
    func announcement() {
        func text(_ p: Double, boosted: Bool = false, boost: Bool = true, ceiling: Double = 200) -> String {
            BrightnessHUDController.announcementText(percentage: p, isBoosted: boosted, supportsBoost: boost, boostCeiling: ceiling)
        }
        #expect(text(60) == "Brightness 60 percent")
        #expect(text(0) == "Brightness 0 percent, minimum")
        #expect(text(120, boosted: true) == "Brightness 120 percent, boosted")
        #expect(text(150, boosted: true, ceiling: 150) == "Brightness 150 percent, boosted, maximum")
        #expect(text(100, boost: false) == "Brightness 100 percent, maximum")
        #expect(text(100, ceiling: 150) == "Brightness 100 percent")
    }

    @Test("reduce motion removes the fade")
    func reduceMotion() {
        let normal = BrightnessHUDController.fadeDurations(reduceMotion: false)
        #expect(normal.fadeIn == 0.12)
        #expect(normal.fadeOut == 0.35)
        let reduced = BrightnessHUDController.fadeDurations(reduceMotion: true)
        #expect(reduced.fadeIn == 0 && reduced.fadeOut == 0)
    }
}

@Suite("HUD fade")
struct HUDFadeMachineTests {
    @Test("a press from hidden fades in, later presses snap to opaque")
    func showActions() {
        var fade = HUDFadeMachine()
        let first = fade.show()
        let second = fade.show()
        #expect(first == .fadeIn)
        #expect(second == .snapOpaque)
        #expect(fade.phase == .visible)
    }

    @Test("a dismissal that nothing overtakes hides the panel")
    func dismissCompletes() {
        var fade = HUDFadeMachine()
        _ = fade.show()
        let generation = fade.beginDismiss()
        #expect(generation != nil)
        #expect(fade.phase == .fadingOut)
        let hidden = fade.finishDismiss(generation: generation ?? -1)
        #expect(hidden)
        #expect(fade.phase == .hidden)
        let next = fade.show()
        #expect(next == .fadeIn)
    }

    @Test("a press during the fade-out cancels it, and the stale completion does nothing")
    func pressDuringFadeOut() {
        var fade = HUDFadeMachine()
        _ = fade.show()
        let stale = fade.beginDismiss() ?? -1
        let action = fade.show()
        let hidden = fade.finishDismiss(generation: stale)
        #expect(action == .snapOpaque)
        #expect(!hidden)
        #expect(fade.phase == .visible)
    }

    @Test("an old completion cannot hide a later fade-out's panel")
    func staleAcrossDismissals() {
        var fade = HUDFadeMachine()
        _ = fade.show()
        let first = fade.beginDismiss() ?? -1
        _ = fade.show()
        let second = fade.beginDismiss() ?? -1
        let staleHidden = fade.finishDismiss(generation: first)
        #expect(!staleHidden)
        #expect(fade.phase == .fadingOut)
        let hidden = fade.finishDismiss(generation: second)
        #expect(hidden)
    }

    @Test("dismissing while hidden or already fading does nothing")
    func noDoubleDismiss() {
        var fade = HUDFadeMachine()
        let whileHidden = fade.beginDismiss()
        #expect(whileHidden == nil)
        _ = fade.show()
        _ = fade.beginDismiss()
        let whileFading = fade.beginDismiss()
        #expect(whileFading == nil)
    }
}

@MainActor
@Suite("HUD style")
struct HUDStyleTests {
    private func version(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }

    @Test("macOS 26 and later take the capsule, earlier systems keep the bezel", arguments: [
        (14, HUDStyle.bezel), (15, .bezel), (25, .bezel), (26, .capsule), (27, .capsule), (30, .capsule)
    ])
    func choice(major: Int, expected: HUDStyle) {
        #expect(HUDStyle.style(for: version(major)) == expected)
        #expect(HUDStyle.style(for: version(major, 9)) == expected)
    }

    @Test("the background is glass only for the capsule on a system that has glass")
    func surface() {
        #expect(HUDStyle.capsule.surface(reduceTransparency: false, glassAvailable: true) == .glass)
        #expect(HUDStyle.capsule.surface(reduceTransparency: false, glassAvailable: false) == .material)
        #expect(HUDStyle.bezel.surface(reduceTransparency: false, glassAvailable: true) == .material)
        #expect(HUDStyle.bezel.surface(reduceTransparency: false, glassAvailable: false) == .material)
    }

    @Test("Reduce Transparency always gives a solid background", arguments: [HUDStyle.bezel, .capsule])
    func solidFallback(style: HUDStyle) {
        #expect(style.surface(reduceTransparency: true, glassAvailable: true) == .solid)
        #expect(style.surface(reduceTransparency: true, glassAvailable: false) == .solid)
    }

    @Test("panel sizes: the bezel is fixed, the capsule grows a line for the paused notice")
    func sizes() {
        #expect(HUDStyle.bezel.panelSize(isBoostPaused: false) == CGSize(width: 190, height: 190))
        #expect(HUDStyle.bezel.panelSize(isBoostPaused: true) == CGSize(width: 190, height: 190))
        #expect(HUDStyle.capsule.panelSize(isBoostPaused: false) == CGSize(width: 300, height: 56))
        #expect(HUDStyle.capsule.panelSize(isBoostPaused: true) == CGSize(width: 300, height: 84))
    }

    @Test("the capsule hangs from the built-in screen's top-right corner")
    func capsuleOrigin() {
        let size = HUDStyle.capsule.panelSize(isBoostPaused: false)
        let origin = BrightnessHUDController.hudOrigin(
            panelSize: size,
            style: .capsule,
            screens: [(id: 7, visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1400)),
                      (id: 1, visibleFrame: CGRect(x: 2560, y: 40, width: 1512, height: 900))],
            isBuiltin: { $0 == 1 }
        )
        #expect(origin == CGPoint(x: 2560 + 1512 - 300 - 12, y: 40 + 900 - 56 - 8))
        #expect(BrightnessHUDController.hudOrigin(
            panelSize: size, style: .capsule,
            screens: [(id: 7, visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100))],
            isBuiltin: { _ in false }
        ) == nil)
    }
}

@MainActor
@Suite("HUD capsule panel", .serialized)
struct HUDCapsulePanelTests {
    @Test("the capsule panel takes the capsule's size and never takes focus or clicks")
    func capsulePanel() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.style = .capsule
        rig.press(150)
        #expect(rig.panel.frame.size == HUDStyle.capsule.panelSize(isBoostPaused: false))
        #expect(rig.panel.ignoresMouseEvents)
        #expect(!rig.panel.canBecomeKey)
        #expect(!rig.panel.canBecomeMain)
        #expect(rig.panel.level == .statusBar)
    }

    @Test("the capsule panel grows for the paused notice")
    func pausedGrowth() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.style = .capsule
        rig.press(150)
        rig.pressPaused()
        #expect(rig.panel.frame.size == HUDStyle.capsule.panelSize(isBoostPaused: true))
        #expect(rig.panel.frame.size.height == 84)
    }

    @Test("switching back to the bezel restores its size")
    func bezelPanel() {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.style = .capsule
        rig.press()
        rig.style = .bezel
        rig.press()
        #expect(rig.panel.frame.size == HUDStyle.bezel.panelSize(isBoostPaused: false))
    }

    @Test("the VoiceOver announcement does not depend on the style", arguments: [HUDStyle.bezel, .capsule])
    func announcement(style: HUDStyle) {
        let rig = HUDRig()
        defer { rig.tearDown() }
        rig.style = style
        rig.press(120)
        rig.fireTimers(delay: BrightnessHUDController.announcementDebounce)
        #expect(rig.posts.count == 1)
        #expect(rig.posts.first?.userInfo[.announcement] as? String == "Brightness 120 percent, boosted")
    }
}
