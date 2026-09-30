import AppKit
import Testing
@testable import BrightBoi

@MainActor
@Suite("Menu bar icon")
struct MenuBarIconTests {
    @Test("the label names the app, the level and Boost")
    func labelText() {
        #expect(BrightnessMenuBarIcon.accessibilityLabel(percentage: 60, isBoosted: false) == "BrightBoi, brightness 60 percent")
        #expect(BrightnessMenuBarIcon.accessibilityLabel(percentage: 149.6, isBoosted: true) == "BrightBoi, brightness 150 percent, boosted")
        #expect(BrightnessMenuBarIcon.accessibilityLabel(percentage: 0, isBoosted: false) == "BrightBoi, brightness 0 percent")
    }

    @Test("different levels and Boost states draw different images")
    func imagesDiffer() {
        let off = BrightnessMenuBarIcon.image(fraction: 0, isBoosted: false)
        let half = BrightnessMenuBarIcon.image(fraction: 0.5, isBoosted: false)
        let boosted = BrightnessMenuBarIcon.image(fraction: 1, isBoosted: true)
        let full = BrightnessMenuBarIcon.image(fraction: 1, isBoosted: false)
        let tiffs = [off, half, boosted, full].compactMap(\.tiffRepresentation)
        #expect(tiffs.count == 4)
        #expect(Set(tiffs).count == 4)
    }

    @Test("every 5% step on an XDR panel moves the glyph")
    func everyFivePercentStepMovesTheGlyph() throws {
        let a = try #require(BrightnessMenuBarIcon.image(fraction: 80.0 / 200, isBoosted: false).tiffRepresentation)
        let b = try #require(BrightnessMenuBarIcon.image(fraction: 85.0 / 200, isBoosted: false).tiffRepresentation)
        #expect(a != b)
    }

    @Test("a cached image equals the first render")
    func cacheIsStable() throws {
        let first = try #require(BrightnessMenuBarIcon.image(fraction: 0.3, isBoosted: false).tiffRepresentation)
        let second = try #require(BrightnessMenuBarIcon.image(fraction: 0.3, isBoosted: false).tiffRepresentation)
        #expect(first == second)
    }

    @Test("images are templates on the fixed canvas and carry the description")
    func templateAndSize() {
        for (fraction, boosted) in [(0.0, false), (0.5, false), (1.0, true)] {
            let image = BrightnessMenuBarIcon.image(fraction: fraction, isBoosted: boosted, description: "described")
            #expect(image.isTemplate)
            #expect(image.size == BrightnessMenuBarIcon.canvasSize)
            #expect(image.accessibilityDescription == "described")
        }
    }

    @Test("a cached image keeps its own description")
    func descriptionIsPerCall() {
        let first = BrightnessMenuBarIcon.image(fraction: 0.25, isBoosted: false, description: "one")
        let second = BrightnessMenuBarIcon.image(fraction: 0.25, isBoosted: false, description: "two")
        #expect(first.accessibilityDescription == "one")
        #expect(second.accessibilityDescription == "two")
    }

    @Test("the fill mask runs from the bottom of the disc to its top")
    func maskHeight() {
        let h: CGFloat = 16
        #expect(BrightnessMenuBarIcon.fillMaskHeight(fraction: 0, canvasHeight: h) == h * BrightnessMenuBarIcon.discBottom)
        let top = BrightnessMenuBarIcon.fillMaskHeight(fraction: 1, canvasHeight: h)
        #expect(abs(top - h * (BrightnessMenuBarIcon.discBottom + BrightnessMenuBarIcon.discHeight)) < 0.0001)
        #expect(BrightnessMenuBarIcon.fillMaskHeight(fraction: 2, canvasHeight: h) == top)
        #expect(BrightnessMenuBarIcon.fillMaskHeight(fraction: -1, canvasHeight: h) == h * BrightnessMenuBarIcon.discBottom)
    }

    @Test("the status item's content carries the label, and not the symbol's own 'Increase Brightness'", accessibilityAvailable)
    func contentAccessibilityLabel() {
        for (percentage, boosted) in [(10.0, false), (75.0, false), (150.0, true)] {
            let rig = ControllerRig(storedPercentage: percentage)
            let host = OffscreenHost(BrightnessMenuBarIcon(controller: rig.controller, settings: .inert()))
            let expected = BrightnessMenuBarIcon.accessibilityLabel(percentage: percentage, isBoosted: boosted)
            // Exactly one element, and it is the label: the drawn glyph adds
            // no element of its own.
            #expect(host.tree.nodes.map(\.name) == [expected], "\(host.tree.dump)")
            #expect(host.tree.spokenTexts.allSatisfy { !$0.localizedCaseInsensitiveContains("increase") })
            #expect(host.tree.spokenTexts.filter { $0.contains("BrightBoi") } == [expected])
            OffscreenWindows.closeAll()
        }
    }

    @Test("the label follows the level as it changes", accessibilityAvailable)
    func labelFollowsTheLevel() throws {
        let rig = ControllerRig(storedPercentage: 40)
        let host = OffscreenHost(BrightnessMenuBarIcon(controller: rig.controller, settings: .inert()))
        defer { OffscreenWindows.closeAll() }
        #expect(host.tree.node(named: "BrightBoi, brightness 40 percent") != nil)
        rig.controller.setPercentage(120)
        host.settle()
        #expect(host.tree.node(named: "BrightBoi, brightness 120 percent, boosted") != nil, "\(host.tree.dump)")
    }
}
