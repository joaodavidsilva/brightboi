import SwiftUI

/// The floating on-screen HUD shown on every recognized Key Remap press
/// (mockups 1c dark / 2c light): a segmented meter matching macOS's own
/// brightness/volume HUD shape, spanning the full 0...200% range with 8
/// extra segments past the old 100% ceiling that pick up the Boost tint
/// once reached. On a non-XDR Mac (`!state.supportsBoost`) only the 8
/// Nominal segments are drawn at all — matching `BoostSlider`'s own
/// "no Boost UI shown on non-XDR" precedent (ticket 01) rather than just
/// dimming out segments that can never fill.
///
/// Takes the whole `BrightnessController.State` (not loose
/// percentage/isBoosted/supportsBoost parameters) since those three values
/// already travel together as one type everywhere else in the app.
struct BrightnessHUDView: View {
    var state: BrightnessController.State

    @Environment(\.colorScheme) private var colorScheme

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
        let palette = BrightnessMenuContent.Palette(colorScheme: colorScheme)

        VStack(spacing: 20) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 44))
                .foregroundStyle(state.isBoosted ? palette.boostBadgeText : palette.primaryText)

            HStack(spacing: 2) {
                ForEach(0..<totalSegmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(segmentColor(index: index, palette: palette))
                        .frame(height: Self.segmentHeight)
                }
            }
            .frame(width: Self.meterWidth)
        }
        .padding(24)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func segmentColor(index: Int, palette: BrightnessMenuContent.Palette) -> Color {
        let isBoostSegment = index >= Self.nominalSegmentCount
        let segmentThreshold = Double(index + 1) * segmentSpan
        let isFilled = state.percentage >= segmentThreshold - 0.01

        if isFilled {
            return isBoostSegment ? palette.boostGradient[1] : palette.nominalFill
        }
        return isBoostSegment ? palette.boostStripe : palette.trackBackground
    }
}
