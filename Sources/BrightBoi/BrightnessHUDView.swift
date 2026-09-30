import SwiftUI

/// The floating on-screen HUD shown on every recognized Key Remap press: a
/// segmented meter in the shape of macOS's own brightness and volume
/// indicator, with the level as a number underneath. The meter spans the full
/// 0...200% range in two groups of 8 segments with a visible gap between them,
/// so the start of Boost reads without relying on colour. A segment fills in
/// proportion to the level inside it, so every 5% press moves the meter.
/// Segments past the user's Boost Ceiling are drawn locked, since a press can
/// never reach them. On a non-XDR Mac (`!state.supportsBoost`) only the 8
/// Nominal segments are drawn at all, matching the popover slider's "no Boost
/// UI on non-XDR" rule rather than dimming segments that can never fill.
///
/// Takes the whole `BrightnessController.State` (not loose
/// percentage/isBoosted/supportsBoost parameters) since those values already
/// travel together as one type everywhere else in the app.
///
/// The HUD is hidden from accessibility: VoiceOver gets the same information
/// as a spoken announcement posted when the HUD is presented.
struct BrightnessHUDView: View {
    var state: BrightnessController.State

    static let panelSize = CGSize(width: 190, height: 190)

    nonisolated static let nominalSegmentCount = 8
    nonisolated static let boostSegmentCount = 8
    private static let meterWidth: CGFloat = 148
    private static let segmentHeight: CGFloat = 7
    private static let segmentSpacing: CGFloat = 2
    private static let groupGap: CGFloat = 5
    private static let segmentCornerRadius: CGFloat = 1.5

    private var totalSegmentCount: Int {
        state.supportsBoost ? Self.nominalSegmentCount + Self.boostSegmentCount : Self.nominalSegmentCount
    }

    private var segmentSpan: Double {
        Self.segmentSpan(supportsBoost: state.supportsBoost)
    }

    // MARK: - Pure helpers

    /// The percentage one segment stands for.
    nonisolated static func segmentSpan(supportsBoost: Bool) -> Double {
        let total = supportsBoost ? nominalSegmentCount + boostSegmentCount : nominalSegmentCount
        return BrightnessController.effectiveMaximum(supportsBoost: supportsBoost) / Double(total)
    }

    /// How full segment `index` is at `percentage`, 0...1: 0 below the
    /// segment, 1 above it, and the fraction of the way through inside it.
    nonisolated static func segmentFill(index: Int, percentage: Double, span: Double) -> Double {
        guard span > 0 else { return 0 }
        return min(max((percentage - Double(index) * span) / span, 0), 1)
    }

    /// Whether segment `index` starts at or past the Boost Ceiling, so no key
    /// press can ever light any of it.
    nonisolated static func isLocked(index: Int, span: Double, ceiling: Double) -> Bool {
        Double(index) * span >= ceiling
    }

    /// The number under the meter.
    nonisolated static func readout(percentage: Double) -> String {
        "\(Int(percentage.rounded()))%"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 14) {
            glyph

            meter

            // Always present, so the number's height is always reserved and
            // the bezel never changes size between presses.
            Text(Self.readout(percentage: state.percentage))
                .font(Theme.Typography.hudReadout)
                .foregroundStyle(Color.textPrimary)

            if state.isBoostPaused {
                Text("Boost paused:\nInvert Colors is on")
                    .font(Theme.Typography.secondaryMedium)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.hud))
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        Image(systemName: "sun.max.fill")
            .font(.system(size: Theme.GlyphSize.hud))
            .foregroundStyle(state.isBoosted ? Color.hudBoost : Color.textPrimary)
            .overlay(alignment: .topTrailing) {
                // The shape cue for Boost, so it does not depend on colour.
                if state.isBoosted {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: Theme.GlyphSize.hudBadge, weight: .bold))
                        .foregroundStyle(Color.hudBoost)
                        .background(Circle().fill(.regularMaterial).padding(-2))
                        .offset(x: 9, y: -6)
                }
            }
    }

    private var meter: some View {
        HStack(spacing: Self.groupGap) {
            segmentGroup(indices: 0..<Self.nominalSegmentCount)
            if state.supportsBoost {
                segmentGroup(indices: Self.nominalSegmentCount..<totalSegmentCount)
            }
        }
        .frame(width: Self.meterWidth)
    }

    private func segmentGroup(indices: Range<Int>) -> some View {
        HStack(spacing: Self.segmentSpacing) {
            ForEach(indices, id: \.self) { index in
                segment(index: index)
            }
        }
    }

    private func segment(index: Int) -> some View {
        let isBoostSegment = index >= Self.nominalSegmentCount
        let locked = state.supportsBoost && Self.isLocked(index: index, span: segmentSpan, ceiling: state.boostCeiling)
        let fill = Self.segmentFill(index: index, percentage: state.percentage, span: segmentSpan)
        let shape = RoundedRectangle(cornerRadius: Self.segmentCornerRadius)

        let track: Color = if locked {
            Color.fillTrack.opacity(0.35)
        } else if isBoostSegment {
            Color.boostStripe
        } else {
            Color.fillTrack
        }
        let lit: Color = isBoostSegment ? Color.hudBoost : Color.sliderNominal

        return shape
            .fill(track)
            .overlay(alignment: .leading) {
                // Leading-aligned, so a partly filled segment grows from its
                // left edge; the clip below keeps the round corners.
                GeometryReader { proxy in
                    Rectangle()
                        .fill(lit)
                        .frame(width: proxy.size.width * fill)
                }
            }
            .clipShape(shape)
            .frame(height: Self.segmentHeight)
            .contrastBorder(cornerRadius: Self.segmentCornerRadius)
    }
}
