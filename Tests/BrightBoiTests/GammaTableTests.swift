import CoreGraphics
import Testing
@testable import BrightBoi

/// `GammaTable.isAlreadyBoosted`/`matches` back `BoostEngagement`'s guard
/// against adopting an already-scaled gamma table as its Boost baseline —
/// exercised here as pure functions over raw samples, without going through
/// `CGGetDisplayTransferByTable`.
@Suite("GammaTable")
struct GammaTableTests {
    private static let sampleCount = 256

    private static func ramp(peakingAt peak: CGGammaValue) -> [CGGammaValue] {
        (0..<sampleCount).map { CGGammaValue($0) / CGGammaValue(sampleCount - 1) * peak }
    }

    @Test("an identity ramp (peak 1.0) does not look already boosted")
    func identityRampIsNotAlreadyBoosted() {
        let identity = Self.ramp(peakingAt: 1.0)
        #expect(GammaTable.isAlreadyBoosted(red: identity, green: identity, blue: identity) == false)
    }

    @Test("a real vcgt-like ramp peaking just under 1.0 does not look already boosted")
    func nearIdentityRampIsNotAlreadyBoosted() {
        // The live built-in panel's table peaks at 0.99999994, not exactly 1.0.
        let nearIdentity = Self.ramp(peakingAt: 0.9999)
        #expect(GammaTable.isAlreadyBoosted(red: nearIdentity, green: nearIdentity, blue: nearIdentity) == false)
    }

    @Test("a x2-scaled ramp looks already boosted")
    func doubledRampLooksAlreadyBoosted() {
        let doubled = Self.ramp(peakingAt: 2.0)
        #expect(GammaTable.isAlreadyBoosted(red: doubled, green: doubled, blue: doubled) == true)
    }

    @Test("only one channel needs to read as boosted for the table to be flagged")
    func anyChannelPeakingHighFlagsTheWholeTable() {
        let identity = Self.ramp(peakingAt: 1.0)
        let doubled = Self.ramp(peakingAt: 2.0)
        #expect(GammaTable.isAlreadyBoosted(red: doubled, green: identity, blue: identity) == true)
    }

    @Test("identical tables match")
    func identicalTablesMatch() {
        let table = GammaTable(red: Self.ramp(peakingAt: 1.0), green: Self.ramp(peakingAt: 1.0), blue: Self.ramp(peakingAt: 1.0))
        #expect(table.matches(table) == true)
    }

    @Test("tables differing within tolerance still match, e.g. hardware-LUT quantization noise")
    func tablesWithinToleranceMatch() {
        let a = GammaTable(red: Self.ramp(peakingAt: 1.0), green: Self.ramp(peakingAt: 1.0), blue: Self.ramp(peakingAt: 1.0))
        let noisy = a.red.map { $0 + 0.0001 }
        let b = GammaTable(red: noisy, green: a.green, blue: a.blue)
        #expect(a.matches(b) == true)
    }

    @Test("tables differing beyond tolerance do not match, e.g. another process took over the display")
    func tablesBeyondToleranceDoNotMatch() {
        let a = GammaTable(red: Self.ramp(peakingAt: 1.0), green: Self.ramp(peakingAt: 1.0), blue: Self.ramp(peakingAt: 1.0))
        let b = GammaTable(red: Self.ramp(peakingAt: 1.8), green: Self.ramp(peakingAt: 1.8), blue: Self.ramp(peakingAt: 1.8))
        #expect(a.matches(b) == false)
    }
}
