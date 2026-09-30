import Foundation
import CoreGraphics
import Testing
@testable import BrightBoi

/// The mapping from the slider to the table factor, and the per-panel
/// ceiling.
@Suite("BoostCalibration")
struct BoostCalibrationTests {
    private func factor(_ fraction: Double, headroom: CGFloat?, curve: BoostCurve = .linear, domain: GammaDomain = .linear) -> CGFloat {
        BoostCalibration.tableFactor(forBoostFraction: fraction, observedHeadroom: headroom, curve: curve, domain: domain)
    }

    @Test("100% is the identity table and 200% is 2.0 on a panel with the full 3.2 of headroom")
    func anchorsOnTheReferencePanel() {
        #expect(factor(0, headroom: 3.2) == 1.0)
        #expect(abs(factor(1, headroom: 3.2) - 2.0) < 1e-9)
    }

    @Test("a panel with less headroom gets a lower 200%: 1000 nits over its own SDR white")
    func lowerCeilingOnBrighterPanels() {
        // A 600-nit panel peaks at 1600, so its headroom is 1600 / 600.
        let headroom: CGFloat = 1600.0 / 600.0
        #expect(abs(factor(1, headroom: headroom) - 1000.0 / 600.0) < 1e-6)
        #expect(factor(1, headroom: headroom) < 2.0)
    }

    @Test("more headroom than needed never raises the ceiling above 2.0")
    func ceilingNeverAboveTwo() {
        #expect(factor(1, headroom: 5.2) == 2.0)
        #expect(factor(1, headroom: 16) == 2.0)
    }

    @Test("an unknown headroom gives the full 2.0, and nonsense is treated as unknown")
    func unknownHeadroom() {
        #expect(factor(1, headroom: nil) == 2.0)
        #expect(factor(1, headroom: .nan) == 2.0)
        #expect(factor(1, headroom: 0.5) == 2.0)
    }

    @Test("a panel with hardly any headroom gets no Boost rather than a factor below 1")
    func ceilingNeverBelowIdentity() {
        #expect(factor(1, headroom: 1.2) == 1.0)
    }

    @Test("the steps are monotonic on both curves, and end where they should", arguments: [BoostCurve.linear, .geometric])
    func monotonic(curve: BoostCurve) {
        var previous: CGFloat = 0
        for step in 0...20 {
            let value = factor(Double(step) / 20, headroom: 2.4, curve: curve)
            #expect(value >= previous)
            previous = value
        }
        #expect(factor(0, headroom: 2.4, curve: curve) == 1.0)
        #expect(abs(factor(1, headroom: 2.4, curve: curve) - 1.5) < 1e-6)
    }

    @Test("the geometric curve takes equal ratio steps")
    func geometricSteps() {
        let a = BoostCurve.geometric.luminanceRatio(forBoostFraction: 0.2, ceilingRatio: 2)
        let b = BoostCurve.geometric.luminanceRatio(forBoostFraction: 0.4, ceilingRatio: 2)
        let c = BoostCurve.geometric.luminanceRatio(forBoostFraction: 0.6, ceilingRatio: 2)
        #expect(abs(b / a - c / b) < 1e-9)
    }

    @Test("a fraction outside 0...1 is clamped")
    func fractionIsClamped() {
        #expect(factor(-1, headroom: 3.2) == 1.0)
        #expect(factor(3, headroom: 3.2) == 2.0)
        #expect(factor(.nan, headroom: 3.2) == 1.0)
    }

    @Test("the active curve and domain are the linear ones until they are measured")
    func activeDefaults() {
        #expect(BoostCurve.active == .linear)
        #expect(GammaDomain.assumed == .linear)
    }

    @Test("a gamma-encoded table needs the root of the luminance ratio")
    func encodedDomain() {
        let encoded = GammaDomain.encoded(gamma: 2.2)
        let table = encoded.tableFactor(forLuminanceRatio: 2.0)
        #expect(abs(table - pow(2.0, 1 / 2.2)) < 1e-12)
        #expect(abs(encoded.luminanceRatio(forTableFactor: table) - 2.0) < 1e-12)
        #expect(GammaDomain.linear.tableFactor(forLuminanceRatio: 2.0) == 2.0)
    }

    @Test("the headroom clamp uses the same domain")
    func headroomClampInEncodedDomain() {
        // Headroom 3.2 in luminance is a table factor of 3.2^(1/2.2) = 1.70.
        let clamped = BoostHeadroom.effectiveFactor(requested: 2.0, headroom: 3.2, domain: .encoded(gamma: 2.2))
        #expect(abs(clamped - CGFloat(pow(3.2, 1 / 2.2))) < 1e-6)
        #expect(BoostHeadroom.effectiveFactor(requested: 2.0, headroom: 3.2, domain: .linear) == 2.0)
    }
}
