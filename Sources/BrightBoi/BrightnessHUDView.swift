import SwiftUI

/// The floating on-screen HUD shown on every recognized Key Remap press: a
/// segmented meter matching macOS's own brightness/volume HUD shape, spanning
/// the full 0...200% range with 8 extra segments past the old 100% ceiling
/// that pick up the Boost tint once reached. On a non-XDR Mac
/// (`!state.supportsBoost`) only the 8 Nominal segments are drawn at all,
/// matching the popover slider's own "no Boost UI on non-XDR" rule rather
/// than dimming out segments that can never fill.
///
/// Takes the whole `BrightnessController.State` (not loose
/// percentage/isBoosted/supportsBoost parameters) since those three values
/// already travel together as one type everywhere else in the app.
struct BrightnessHUDView: View {
    var state: BrightnessController.State

    static let panelSize = CGSize(width: 190, height: 190)

    private static let nominalSegmentCount = 8
    private static let boostSegmentCount = 8
    private static let meterWidth: CGFloat = 148
    private static let segmentHeight: CGFloat = 7

    private var totalSegmentCount: Int {
        state.supportsBoost ? Self.nominalSegmentCount + Self.boostSegmentCount : Self.nominalSegmentCount
    }

    private var segmentSpan: Double {
        BrightnessController.effectiveMaximum(supportsBoost: state.supportsBoost) / Double(totalSegmentCount)
    }

    var body: some View {
        VStack(spacing: state.isBoostPaused ? 14 : 20) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: Theme.GlyphSize.hud))
                .foregroundStyle(state.isBoosted ? Color.boost : Color.textPrimary)

            HStack(spacing: 2) {
                ForEach(0..<totalSegmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(segmentColor(index: index))
                        .frame(height: Self.segmentHeight)
                        .contrastBorder(cornerRadius: 1)
                }
            }
            .frame(width: Self.meterWidth)

            if state.isBoostPaused {
                Text("Boost paused — Invert Colors is on")
                    .font(Theme.Typography.secondaryMedium)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.hud))
    }

    private func segmentColor(index: Int) -> Color {
        let isBoostSegment = index >= Self.nominalSegmentCount
        let segmentThreshold = Double(index + 1) * segmentSpan
        let isFilled = state.percentage >= segmentThreshold - 0.01

        if isFilled {
            return isBoostSegment ? Color.boost : Color.sliderNominal
        }
        return isBoostSegment ? Color.boostStripe : Color.fillTrack
    }
}
