import SwiftUI

/// Which look the key-press HUD takes. macOS 26 and later draws its own
/// volume and brightness indicator as a compact capsule at the top right, so
/// the HUD follows it there; earlier systems keep the rounded-square bezel.
enum HUDStyle: Equatable, Sendable {
    /// A rounded square near the bottom of the screen: glyph, meter, number.
    case bezel
    /// A Liquid Glass capsule under the menu bar at the top right: glyph,
    /// meter and number in one row.
    case capsule

    /// The first macOS release whose own indicator is the capsule.
    nonisolated static let capsuleMinimumMajorVersion = 26

    /// The style for a system version. Pure, so both branches can be tested
    /// on any machine.
    nonisolated static func style(for version: OperatingSystemVersion) -> HUDStyle {
        version.majorVersion >= capsuleMinimumMajorVersion ? .capsule : .bezel
    }

    /// The style for the system this process runs on.
    nonisolated static var current: HUDStyle {
        style(for: ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// What the HUD's background is made of.
    enum Surface: Equatable, Sendable {
        /// The system's Liquid Glass (macOS 26 and later only).
        case glass
        /// A translucent system material.
        case material
        /// An opaque Theme colour, for Reduce Transparency.
        case solid
    }

    /// The background for a style. Reduce Transparency always wins, and glass
    /// needs both the capsule style and a system that has it.
    nonisolated func surface(reduceTransparency: Bool, glassAvailable: Bool = HUDStyle.glassAvailable) -> Surface {
        if reduceTransparency { return .solid }
        return self == .capsule && glassAvailable ? .glass : .material
    }

    /// Whether this process can draw Liquid Glass: the running system has it
    /// and the SDK the app was built with knows the API.
    nonisolated static var glassAvailable: Bool {
        // The compiler check stands in for "the SDK has glassEffect": the
        // toolchain that ships the macOS 26 SDK is Swift 6.2 or later.
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    /// The panel's size. The capsule grows a second line for the Boost
    /// paused notice; the bezel reserves room for it in every state.
    nonisolated func panelSize(isBoostPaused: Bool) -> CGSize {
        switch self {
        case .bezel: CGSize(width: 190, height: 190)
        case .capsule: CGSize(width: 300, height: isBoostPaused ? 84 : 56)
        }
    }

    /// The gap between the panel and the edges of the screen's usable area
    /// it hangs from, for the capsule's top-right corner.
    nonisolated static let capsuleInset = CGSize(width: 12, height: 8)
}

/// The floating on-screen HUD shown on every recognized Key Remap press: a
/// segmented meter in the shape of macOS's own brightness and volume
/// indicator, with the level as a number. The meter spans the full
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
    var style: HUDStyle = .bezel
    /// Replaces the system's Reduce Transparency setting, for rendering the
    /// solid look without changing it.
    var reduceTransparencyOverride: Bool?

    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    nonisolated static let nominalSegmentCount = 8
    nonisolated static let boostSegmentCount = 8
    private static let meterWidth: CGFloat = 148
    private static let capsuleMeterWidth: CGFloat = 168
    private static let capsuleGlyphSize: CGFloat = 17
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

    private var panelSize: CGSize { style.panelSize(isBoostPaused: state.isBoostPaused) }

    // MARK: - Body

    var body: some View {
        Group {
            switch style {
            case .bezel: bezel
            case .capsule: capsule
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background { background }
        .accessibilityHidden(true)
    }

    private var bezel: some View {
        VStack(spacing: 14) {
            glyph(size: Theme.GlyphSize.hud, badgeSize: Theme.GlyphSize.hudBadge, badgeOffset: CGSize(width: 9, height: -6))

            meter(width: Self.meterWidth)

            // Always present, so the number's height is always reserved and
            // the bezel never changes size between presses.
            readout

            if state.isBoostPaused {
                Text("Boost paused:\nInvert Colors is on")
                    .font(Theme.Typography.secondaryMedium)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
    }

    private var capsule: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                glyph(size: Self.capsuleGlyphSize, badgeSize: Theme.GlyphSize.hudCapsuleBadge, badgeOffset: CGSize(width: 6, height: -4))
                    .frame(width: 24)
                meter(width: Self.capsuleMeterWidth)
                readout
                    .frame(width: 40, alignment: .trailing)
            }
            if state.isBoostPaused {
                Text("Boost paused: Invert Colors is on")
                    .font(Theme.Typography.secondaryMedium)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 20)
    }

    private var readout: some View {
        Text(Self.readout(percentage: state.percentage))
            .font(Theme.Typography.hudReadout)
            .foregroundStyle(Color.textPrimary)
    }

    private var surface: HUDStyle.Surface {
        style.surface(reduceTransparency: reduceTransparencyOverride ?? systemReduceTransparency)
    }

    /// The shape of the HUD's background, border and glass.
    private var shape: AnyShape {
        switch style {
        case .bezel: AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.hud))
        case .capsule: AnyShape(Capsule())
        }
    }

    @ViewBuilder
    private var background: some View {
        switch surface {
        case .solid:
            shape.fill(Color.surfaceWindow).overlay { surfaceBorder }
        case .material:
            shape.fill(.regularMaterial).overlay { surfaceBorder }
        case .glass:
            glassBackground
        }
    }

    /// The hairline Increase Contrast draws around the whole HUD.
    @ViewBuilder
    private var surfaceBorder: some View {
        if Theme.isIncreasedContrast(contrast) {
            shape.stroke(Color.textPrimary.opacity(0.5), lineWidth: 2).clipShape(shape)
        }
    }

    @ViewBuilder
    private var glassBackground: some View {
        // The compiler check stands in for "the SDK has glassEffect": the
        // toolchain that ships the macOS 26 SDK is Swift 6.2 or later.
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
                .overlay { surfaceBorder }
        } else {
            shape.fill(.regularMaterial).overlay { surfaceBorder }
        }
        #else
        shape.fill(.regularMaterial).overlay { surfaceBorder }
        #endif
    }

    private func glyph(size: CGFloat, badgeSize: CGFloat, badgeOffset: CGSize) -> some View {
        Image(systemName: "sun.max.fill")
            .font(.system(size: size))
            .foregroundStyle(state.isBoosted ? Color.hudBoost : Color.textPrimary)
            .overlay(alignment: .topTrailing) {
                // The shape cue for Boost, so it does not depend on colour.
                if state.isBoosted {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: badgeSize, weight: .bold))
                        .foregroundStyle(Color.hudBoost)
                        .background(Circle().fill(badgeBackdrop).padding(-2))
                        .offset(x: badgeOffset.width, y: badgeOffset.height)
                }
            }
    }

    /// Behind the Boost arrow, so it stays legible over the glyph's rays.
    private var badgeBackdrop: AnyShapeStyle {
        surface == .solid ? AnyShapeStyle(Color.surfaceWindow) : AnyShapeStyle(.regularMaterial)
    }

    private func meter(width: CGFloat) -> some View {
        HStack(spacing: Self.groupGap) {
            segmentGroup(indices: 0..<Self.nominalSegmentCount)
            if state.supportsBoost {
                segmentGroup(indices: Self.nominalSegmentCount..<totalSegmentCount)
            }
        }
        .frame(width: width)
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
