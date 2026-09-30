import AppKit
import CoreGraphics
import Testing
@testable import BrightBoi

/// The pure decisions behind Boost detection and gamma clamping, plus the
/// overlay window's placement and privacy properties. None of these need a
/// display or a GPU.
@Suite("BoostHeadroom")
struct BoostHeadroomTests {
    // MARK: Detection

    @Test("an XDR panel's potential headroom (16.0) can boost")
    func xdrPotentialCanBoost() {
        #expect(BoostHeadroom.hasBoostHeadroom(potential: 16.0) == true)
    }

    @Test("an ordinary panel (1.0) cannot boost")
    func ordinaryPanelCannotBoost() {
        #expect(BoostHeadroom.hasBoostHeadroom(potential: 1.0) == false)
    }

    @Test("a momentarily missing screen keeps the previous verdict")
    func missingScreenKeepsPreviousVerdict() {
        #expect(BoostHeadroom.boostSupport(potential: nil, previousVerdict: true) == true)
        #expect(BoostHeadroom.boostSupport(potential: nil, previousVerdict: false) == false)
        #expect(BoostHeadroom.boostSupport(potential: nil, previousVerdict: nil) == false)
    }

    @Test("a readable value always overrides the previous verdict")
    func readableValueOverridesPreviousVerdict() {
        #expect(BoostHeadroom.boostSupport(potential: 1.0, previousVerdict: true) == false)
        #expect(BoostHeadroom.boostSupport(potential: 16.0, previousVerdict: false) == true)
    }

    @Test("an unreadable value (no screen) cannot boost")
    func missingPotentialCannotBoost() {
        #expect(BoostHeadroom.hasBoostHeadroom(potential: nil) == false)
        #expect(BoostHeadroom.hasBoostHeadroom(potential: .nan) == false)
        #expect(BoostHeadroom.hasBoostHeadroom(potential: .infinity) == false)
    }

    @Test("the threshold is exactly the headroom 200% needs")
    func thresholdBoundary() {
        let threshold = BoostHeadroom.minimumPotentialForBoost
        #expect(threshold == 2.0)
        #expect(BoostHeadroom.hasBoostHeadroom(potential: threshold) == true)
        #expect(BoostHeadroom.hasBoostHeadroom(potential: threshold - 0.01) == false)
    }

    // MARK: Effective factor

    @Test("with plenty of headroom the requested factor is used as is")
    func effectiveFactorWithAmpleHeadroom() {
        #expect(BoostHeadroom.effectiveFactor(requested: 1.05, headroom: 3.2) == 1.05)
        #expect(BoostHeadroom.effectiveFactor(requested: 2.0, headroom: 3.2) == 2.0)
    }

    @Test("a shortfall in headroom boosts less instead of clipping")
    func effectiveFactorIsClampedToHeadroom() {
        #expect(BoostHeadroom.effectiveFactor(requested: 2.0, headroom: 1.2) == 1.2)
        #expect(BoostHeadroom.effectiveFactor(requested: 1.05, headroom: 1.0) == 1.0)
    }

    @Test("the factor is never below identity, whatever the headroom reads")
    func effectiveFactorNeverBelowIdentity() {
        #expect(BoostHeadroom.effectiveFactor(requested: 1.5, headroom: 0.5) == 1.0)
        #expect(BoostHeadroom.effectiveFactor(requested: 1.5, headroom: 0) == 1.0)
    }

    @Test("non-finite input falls back to identity")
    func effectiveFactorHandlesNonFiniteInput() {
        #expect(BoostHeadroom.effectiveFactor(requested: .nan, headroom: 3.2) == 1.0)
        #expect(BoostHeadroom.effectiveFactor(requested: 2.0, headroom: .nan) == 1.0)
    }

    @Test("tiny headroom changes do not rewrite the table")
    func rewriteToleranceIgnoresNoise() {
        #expect(BoostHeadroom.shouldRewrite(from: 1.5, to: 1.51) == false)
        #expect(BoostHeadroom.shouldRewrite(from: 1.5, to: 1.6) == true)
        #expect(BoostHeadroom.shouldRewrite(from: 1.6, to: 1.5) == true)
    }

    // MARK: Built-in display resolution

    @Test("the built-in display is picked from the displays it is among")
    func builtInPickedFromList() {
        let id = BuiltInDisplay.builtInID(among: [7, 1, 3], isBuiltIn: { $0 == 1 })
        #expect(id == 1)
    }

    @Test("with no built-in display there is no result, never the first or main display")
    func noBuiltInMeansNoResult() {
        #expect(BuiltInDisplay.builtInID(among: [7, 3], isBuiltIn: { _ in false }) == nil)
        #expect(BuiltInDisplay.builtInID(among: [], isBuiltIn: { _ in true }) == nil)
    }

    // MARK: Overlay window

    @Test("the overlay sits at the top-left corner of the built-in screen, in global coordinates")
    func overlayFrameForMainScreen() {
        let frame = EDROverlayWindow.overlayFrame(in: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        #expect(frame == CGRect(x: 0, y: 1116, width: 1, height: 1))
    }

    @Test("the overlay follows a built-in screen that is not at the global origin")
    func overlayFrameForOffsetScreen() {
        let frame = EDROverlayWindow.overlayFrame(in: CGRect(x: -1728, y: 200, width: 1728, height: 1117))
        #expect(frame == CGRect(x: -1728, y: 1316, width: 1, height: 1))
    }

    @MainActor
    @Test("the overlay window is hidden from capture, sharing and accessibility")
    func overlayWindowIsInvisibleToCaptureAndAccessibility() {
        let window = EDROverlayWindow.makeWindow(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(window.sharingType == .none)
        #expect(window.isAccessibilityElement() == false)
        #expect(window.title.isEmpty)
    }

    @MainActor
    @Test("the overlay window is click-through, borderless and above everything")
    func overlayWindowBehaviour() {
        let frame = CGRect(x: 10, y: 20, width: 1, height: 1)
        let window = EDROverlayWindow.makeWindow(frame: frame)
        #expect(window.ignoresMouseEvents == true)
        #expect(window.level == .screenSaver)
        #expect(window.styleMask.isEmpty)
        #expect(window.canHide == false)
        #expect(window.hasShadow == false)
        #expect(window.frame == frame)
    }

    @Test("the disengaged overlay draws nothing at all")
    func disengagedClearColorIsTransparent() {
        let color = EDROverlayWindow.disengagedClearColor
        #expect(color.alpha == 0)
        #expect(color.red == 0 && color.green == 0 && color.blue == 0)
    }

    @Test("the engaged overlay draws a premultiplied, near-invisible value")
    func engagedClearColorIsNearInvisible() {
        let color = EDROverlayWindow.engagedClearColor
        #expect(color.alpha <= 0.02)
        // Premultiplied: colour never exceeds alpha times the 1.6 light level.
        #expect(color.red <= color.alpha * 2)
    }

    // MARK: Engagement without a display

    @MainActor
    @Test("engaging with no built-in display does nothing and reports it")
    func engageWithoutDisplayReportsUnavailable() {
        let engagement = BoostEngagement(displayID: nil)
        #expect(engagement.engage(boostFraction: 0.5) == .displayUnavailable)
        #expect(engagement.isEngaged == false)
    }

    @MainActor
    @Test("disengaging without ever engaging is harmless")
    func disengageWithoutEngageIsHarmless() {
        let engagement = BoostEngagement(displayID: nil)
        engagement.disengage()
        #expect(engagement.isEngaged == false)
        #expect(engagement.effectiveFactor == 1.0)
    }
}
