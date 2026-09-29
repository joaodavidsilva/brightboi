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

    /// A table as a real display reads it back: the system never reports a
    /// sample above 1.0, so a scaled table arrives clamped.
    private static func readBack(_ table: GammaTable) -> GammaTable {
        GammaTable(red: table.red.map { min($0, 1) }, green: table.green.map { min($0, 1) }, blue: table.blue.map { min($0, 1) })
    }

    private static func identityTable() -> GammaTable {
        GammaTable(red: ramp(peakingAt: 1.0), green: ramp(peakingAt: 1.0), blue: ramp(peakingAt: 1.0))
    }

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

    @Test("a boosted table this instance wrote still matches its own clamped read-back")
    func boostedTableMatchesItsClampedReadBack() {
        let written = Self.identityTable().scaled(by: 1.5)
        #expect(written.matches(Self.readBack(written)) == true)
        #expect(Self.readBack(written).matches(written) == true)
    }

    @Test("a clamped read-back of a scaled table looks already boosted, though its peak is 1.0")
    func clampedScaledTableLooksAlreadyBoosted() {
        let readBack = Self.readBack(Self.identityTable().scaled(by: 1.5))
        #expect(readBack.red.max() == 1.0)
        #expect(readBack.looksAlreadyBoosted == true)
    }

    @Test("even a small scale-up is caught by its plateau")
    func smallScaleUpIsCaught() {
        let readBack = Self.readBack(Self.identityTable().scaled(by: 1.05))
        #expect(readBack.looksAlreadyBoosted == true)
    }

    @Test("a table that dims (a tint or night-shift style curve) is not boosted")
    func dimmedTableIsNotBoosted() {
        let dimmed = Self.identityTable().scaled(by: 0.9)
        #expect(dimmed.looksAlreadyBoosted == false)
        #expect(dimmed.isPlainBaseline == true)
    }

    @Test("a table whose last few samples sit at 1.0 is still plain")
    func shortTopPlateauIsPlain() {
        var samples = Self.ramp(peakingAt: 1.0)
        for i in (samples.count - 3)..<samples.count { samples[i] = 1.0 }
        let table = GammaTable(red: samples, green: samples, blue: samples)
        #expect(table.looksAlreadyBoosted == false)
    }

    @Test("a table that goes down somewhere is not a plain baseline")
    func nonMonotonicTableIsNotPlainBaseline() {
        var samples = Self.ramp(peakingAt: 0.9)
        samples[100] = samples[99] - 0.05
        let table = GammaTable(red: samples, green: samples, blue: samples)
        #expect(table.isPlainBaseline == false)
    }

    // MARK: Baseline decision

    @Test("with nothing written yet, a plain table becomes the baseline")
    func decisionAdoptsPlainTableWhenNothingWritten() {
        #expect(GammaTable.baselineDecision(live: Self.identityTable(), lastWritten: nil) == .adopt)
    }

    @Test("with nothing written yet, an already boosted table means another app is boosting")
    func decisionRefusesBoostedTableWhenNothingWritten() {
        let boosted = Self.readBack(Self.identityTable().scaled(by: 1.5))
        #expect(GammaTable.baselineDecision(live: boosted, lastWritten: nil) == .foreignBooster)
    }

    @Test("when the live table is the one just written, the baseline is kept")
    func decisionKeepsBaselineWhenTableIsOurs() {
        let written = Self.identityTable().scaled(by: 1.5)
        #expect(GammaTable.baselineDecision(live: Self.readBack(written), lastWritten: written) == .keep)
    }

    @Test("when something else changed the table to a plain one, that becomes the new baseline")
    func decisionAdoptsPlainReplacement() {
        let written = Self.identityTable().scaled(by: 1.5)
        let tinted = Self.identityTable().scaled(by: 0.9)
        #expect(GammaTable.baselineDecision(live: tinted, lastWritten: written) == .adopt)
    }

    @Test("when the system resets the table after a wake, the reset table is adopted")
    func decisionAdoptsSystemResetAfterWake() {
        let written = Self.identityTable().scaled(by: 1.5)
        #expect(GammaTable.baselineDecision(live: Self.identityTable(), lastWritten: written) == .adopt)
    }

    @Test("when something else replaced our table with a boosted one, it is a foreign booster")
    func decisionRefusesForeignBoostedReplacement() {
        let written = Self.identityTable().scaled(by: 1.2)
        let other = Self.readBack(Self.identityTable().scaled(by: 1.9))
        #expect(GammaTable.baselineDecision(live: other, lastWritten: written) == .foreignBooster)
    }

    // MARK: Capture trimming

    @Test("only the samples the system filled in are kept")
    func trimKeepsOnlyValidSamples() throws {
        let full = Self.ramp(peakingAt: 1.0)
        let table = try #require(GammaTable.trimmed(red: full, green: full, blue: full, validSampleCount: 100))
        #expect(table.red.count == 100)
        #expect(table.green.count == 100)
        #expect(table.blue.count == 100)
        #expect(table.red == Array(full.prefix(100)))
    }

    @Test("a reported count beyond what was requested is capped, not trusted")
    func trimCapsAtBufferSize() throws {
        let full = Self.ramp(peakingAt: 1.0)
        let table = try #require(GammaTable.trimmed(red: full, green: full, blue: full, validSampleCount: 10_000))
        #expect(table.red.count == full.count)
    }

    @Test("a capture with no valid samples is a failure")
    func trimRejectsEmptyCapture() {
        let full = Self.ramp(peakingAt: 1.0)
        #expect(GammaTable.trimmed(red: full, green: full, blue: full, validSampleCount: 0) == nil)
    }
}
