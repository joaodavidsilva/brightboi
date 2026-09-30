import AppKit
import SwiftUI
import Testing
@testable import BrightBoi

/// What assistive technology sees in BrightBoi's real views, read from the
/// accessibility tree of each view hosted in an off-screen window, and what
/// the controls do when pressed the way VoiceOver presses them.
// MARK: - Popover slider (#11)

@MainActor
@Suite("Popover accessibility", .serialized, accessibilityAvailable)
struct PopoverAccessibilityTests {
    private func popover(
        _ rig: ControllerRig,
        quit: @escaping @MainActor () -> Void = {}
    ) -> OffscreenHost<BrightnessMenuContent> {
        OffscreenHost(BrightnessMenuContent(controller: rig.controller, updates: nil, settings: .inert(), quit: quit))
    }

    private func slider(in host: OffscreenHost<BrightnessMenuContent>) throws -> AXNode {
        let sliders = host.tree.nodes(role: .slider)
        #expect(sliders.count == 1, "the popover has one adjustable element")
        return try #require(sliders.first)
    }

    @Test("the track is one adjustable slider named Brightness, with a spoken value that includes Boost")
    func sliderIsOneNamedAdjustableElement() throws {
        defer { OffscreenWindows.closeAll() }
        let host = popover(ControllerRig(storedPercentage: 150))
        let slider = try slider(in: host)
        #expect(slider.name == "Brightness")
        #expect(slider.valueDescription == "150 percent, boosted")
        #expect(slider.frame.width > 200, "the element covers the track row, not a sliver")
    }

    @Test("the spoken value follows the level: plain below 100, boosted above, maximum at the end")
    func sliderValueFollowsLevel() throws {
        defer { OffscreenWindows.closeAll() }
        for (level, expected) in [(40.0, "40 percent"), (100.0, "100 percent"), (185.0, "185 percent, boosted"), (200.0, "200 percent, boosted, maximum")] {
            let host = popover(ControllerRig(storedPercentage: level))
            #expect(try slider(in: host).valueDescription == expected, "at \(level)")
            OffscreenWindows.closeAll()
        }
    }

    @Test("a lowered Boost Ceiling is spoken with the level, and is the slider's top")
    func sliderNamesTheCeiling() throws {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig(storedPercentage: 150, storedBoostCeiling: 150)
        let host = popover(rig)
        #expect(try slider(in: host).valueDescription == "150 percent, boosted, maximum, Boost Ceiling 150 percent")
        // Incrementing at the top changes nothing.
        try slider(in: host).increment()
        #expect(rig.controller.currentState.percentage == 150)
    }

    @Test("increment and decrement step 5% through the controller, without the HUD")
    func sliderStepsByFivePercent() throws {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig(storedPercentage: 150)
        let hudPresses = CallCount()
        rig.controller.onKeyPress = { _, _ in hudPresses.value += 1 }
        let host = popover(rig)

        #expect(try slider(in: host).increment())
        #expect(rig.controller.currentState.percentage == 155)
        host.settle()
        #expect(try slider(in: host).valueDescription == "155 percent, boosted")

        #expect(try slider(in: host).decrement())
        #expect(try slider(in: host).decrement())
        #expect(rig.controller.currentState.percentage == 145)
        #expect(rig.display.appliedPercentages.suffix(3) == [155, 150, 145])
        #expect(hudPresses.value == 0, "adjusting the slider never raises the key-press HUD")
    }

    @Test("no sequence of decrements reaches 0%")
    func decrementStopsAboveZero() throws {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig(storedPercentage: 30)
        let host = popover(rig)
        for _ in 0..<12 {
            try slider(in: host).decrement()
            host.settle()
        }
        #expect(rig.controller.currentState.percentage == BrightnessController.percentageGranularity)
        #expect(!rig.display.appliedPercentages.contains(0))
    }

    @Test("with the built-in display off the slider ignores VoiceOver adjustment")
    func sliderIgnoresAdjustmentWhileDisplayIsOff() throws {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig(storedPercentage: 60, builtInDisplayAvailable: false)
        let host = popover(rig)
        let applied = rig.display.appliedPercentages.count
        try slider(in: host).increment()
        try slider(in: host).decrement()
        #expect(rig.display.appliedPercentages.count == applied)
        #expect(rig.controller.currentState.percentage == 60)
    }

    @Test("the readout, nits and range captions are not announced apart from the slider")
    func readoutAndCaptionsAreHidden() {
        defer { OffscreenWindows.closeAll() }
        let host = popover(ControllerRig(storedPercentage: 150))
        let texts = host.tree.spokenTexts
        #expect(!texts.contains("150%"))
        #expect(!texts.contains { $0.contains("nits") })
        #expect(!texts.contains("0%") && !texts.contains("200%") && !texts.contains { $0.hasPrefix("100% ·") })
    }

    @Test("every element speaks, button names are unique, and decorative glyphs are hidden")
    func popoverStructure() {
        defer { OffscreenWindows.closeAll() }
        let host = popover(ControllerRig(storedPercentage: 150))
        #expect(host.tree.blankElements.isEmpty, "blank: \(host.tree.blankElements.map(\.summary))")
        #expect(Set(host.tree.buttonNames).count == host.tree.buttonNames.count, "\(host.tree.buttonNames)")
        #expect(host.tree.nodes(role: .image).isEmpty)
        #expect(host.tree.buttonNames == ["Dim", "100%", "Max boi", "Settings…", "Quit BrightBoi"])
    }

    @Test("the quick-set buttons set their levels, and Quit goes through its seam")
    func popoverButtonsAct() throws {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig(storedPercentage: 150)
        let quits = CallCount()
        let host = popover(rig, quit: { quits.value += 1 })
        let tree = host.tree
        #expect(try #require(tree.node(named: "Dim")).press())
        #expect(rig.controller.currentState.percentage == 40)
        #expect(try #require(tree.node(named: "Max boi")).press())
        #expect(rig.controller.currentState.percentage == 200)
        #expect(quits.value == 0)
        #expect(try #require(tree.node(named: "Quit BrightBoi")).press())
        #expect(quits.value == 1)
    }

    // MARK: Keyboard focus

    /// SwiftUI stands a proxy in the window's key-view loop for every
    /// control that can take keyboard focus. They are laid out in the order
    /// the loop visits them.
    private func keyViewProxies(in host: OffscreenHost<BrightnessMenuContent>) -> [NSView] {
        host.hosting.subviews.filter { String(describing: type(of: $0)).contains("KeyViewProxy") }
    }

    @Test("the slider is in the key-view loop first, ahead of the buttons, as a stock control would be")
    func sliderJoinsTheKeyViewLoop() throws {
        defer { OffscreenWindows.closeAll() }
        let host = popover(ControllerRig(storedPercentage: 150))
        let proxies = keyViewProxies(in: host)
        // The slider, Dim, 100%, Max boi, Settings and Quit.
        #expect(proxies.count == 6)
        let slider = try #require(proxies.first)
        #expect(slider.frame.height == BoostSlider.rowHeight && slider.frame.width > 200)
        #expect(proxies.map(\.frame.minY) == proxies.map(\.frame.minY).sorted(), "loop order follows the layout, top to bottom")
        #expect(slider.frame.minY < proxies[1].frame.minY)
    }

    @Test("a stock button's proxy and the slider's proxy accept focus alike, and neither holds it on opening")
    func sliderFocusMatchesStockControls() throws {
        defer { OffscreenWindows.closeAll() }
        let host = popover(ControllerRig(storedPercentage: 150))
        let proxies = keyViewProxies(in: host)
        let slider = try #require(proxies.first)
        // Whatever the user's Keyboard navigation setting, the slider's proxy
        // answers as the buttons' do. (Offscreen the setting itself is not
        // changed, so whether focus is granted with it on is not proven here;
        // that a bare focusable would also draw a ring is a human check.)
        for proxy in proxies.dropFirst() {
            #expect(slider.canBecomeKeyView == proxy.canBecomeKeyView)
            #expect(slider.acceptsFirstResponder == proxy.acceptsFirstResponder)
        }
        #expect(!proxies.contains { host.window.firstResponder === $0 }, "opening focuses nothing")
    }

    @Test("with the slider focused, the arrow keys step 5% through the controller, without the HUD, and never reach 0%")
    func arrowKeysAdjustTheSlider() throws {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig(storedPercentage: 150)
        let hudPresses = CallCount()
        rig.controller.onKeyPress = { _, _ in hudPresses.value += 1 }
        let host = popover(rig)
        let slider = try #require(keyViewProxies(in: host).first)
        #expect(host.window.makeFirstResponder(slider))
        // SwiftUI takes the new first responder into its focus on a later
        // pass of the run loop (macOS 15 is slower at it), so let it, or the
        // first key press arrives before anything is focused.
        host.settle()
        host.settle()

        func press(_ code: UInt16, _ scalar: Int) {
            host.press(key: code, characters: String(UnicodeScalar(scalar)!))
            host.settle()
        }
        press(126, NSUpArrowFunctionKey)
        #expect(rig.controller.currentState.percentage == 155)
        press(124, NSRightArrowFunctionKey)
        #expect(rig.controller.currentState.percentage == 160)
        press(125, NSDownArrowFunctionKey)
        #expect(rig.controller.currentState.percentage == 155)
        press(123, NSLeftArrowFunctionKey)
        #expect(rig.controller.currentState.percentage == 150)
        for _ in 0..<40 { press(125, NSDownArrowFunctionKey) }
        #expect(rig.controller.currentState.percentage == BrightnessController.percentageGranularity)
        #expect(!rig.display.appliedPercentages.contains(0))
        #expect(hudPresses.value == 0, "the arrow keys on the slider never raise the key-press HUD")
    }
}
