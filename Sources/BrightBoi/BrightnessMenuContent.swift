import AppKit
import SwiftUI

/// The dropdown shown when the menu bar icon is clicked: one continuous
/// slider spanning Nominal Brightness and Extended Brightness / Boost
/// (0–200%), per the spec's "one smooth motion, not a separate mode" design.
/// Dragging below 100% is byte-identical to ticket 04's behavior; the
/// controller (not this view) owns where the Nominal/Boost boundary falls.
///
/// Visuals follow the design mockups' popover (1a dark / 2a light) — a
/// custom-drawn track replaces the stock `Slider` because the stock control
/// can't render the boost-zone stripe hint, the two-tone fill, or the
/// boundary tick the mockups call for. Every color here is looked up from
/// `colorScheme` explicitly (ticket 01) rather than left to automatic
/// semantic colors, since several mockup colors — the boost amber in
/// particular — have genuinely different hex values in light vs. dark, not
/// just an automatic light/dark inversion.
struct BrightnessMenuContent: View {
    var controller: BrightnessController

    @Environment(\.colorScheme) private var colorScheme

    /// Matches the level BrightBoi's own design already assumes as "low
    /// light" (spec user story 2), not an arbitrary round number.
    private static let dimPercentage: Double = 40

    var body: some View {
        let state = controller.currentState
        let palette = Palette(colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            header(state: state, palette: palette)
            readout(state: state, palette: palette)

            VStack(alignment: .leading, spacing: 2) {
                BoostSlider(
                    percentage: state.percentage,
                    supportsBoost: state.supportsBoost,
                    palette: palette,
                    onChange: { controller.setPercentage($0) }
                )
                rangeCaptions(palette: palette)
            }

            quickSetRow(state: state, palette: palette)

            Rectangle()
                .fill(palette.divider)
                .frame(height: 0.5)
                .padding(.horizontal, -14)

            actionsList(palette: palette)
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 8, trailing: 14))
        .frame(width: 280)
    }

    private func header(state: BrightnessController.State, palette: Palette) -> some View {
        HStack {
            HStack(spacing: 7) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.primaryText)
                Text("BrightBoi")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
            }
            Spacer()
            if state.isBoosted {
                Text("BOOSTED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(palette.boostBadgeText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(palette.boostBadgeBackground, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private func readout(state: BrightnessController.State, palette: Palette) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text("\(Int(state.percentage.rounded()))%")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Text("\(Int(state.nits.rounded())) nits")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
        }
    }

    private func rangeCaptions(palette: Palette) -> some View {
        HStack {
            Text("0")
            Spacer()
            Text("100% · 500 nits")
            Spacer()
            Text("200%")
        }
        .font(.system(size: 10))
        .foregroundStyle(palette.tertiaryText)
    }

    private func quickSetRow(state: BrightnessController.State, palette: Palette) -> some View {
        HStack(spacing: 6) {
            quickSetButton(title: "Dim", isPrimary: false, palette: palette) {
                controller.setPercentage(Self.dimPercentage)
            }
            quickSetButton(title: "100%", isPrimary: false, palette: palette) {
                controller.setPercentage(BrightnessController.nominalCeilingPercentage)
            }
            quickSetButton(title: "Max boi", isPrimary: true, palette: palette) {
                controller.setPercentage(BrightnessController.effectiveMaximum(supportsBoost: state.supportsBoost))
            }
        }
    }

    private func quickSetButton(
        title: String,
        isPrimary: Bool,
        palette: Palette,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isPrimary ? .semibold : .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(isPrimary ? palette.quickSetMaxText : palette.primaryText)
                .background(
                    isPrimary ? palette.quickSetMaxBackground : palette.quickSetBackground,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
    }

    private func actionsList(palette: Palette) -> some View {
        VStack(spacing: 0) {
            SettingsLink {
                actionRow(title: "Settings…", shortcut: "⌘,", palette: palette)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                actionRow(title: "Quit BrightBoi", shortcut: "⌘Q", palette: palette)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func actionRow(title: String, shortcut: String, palette: Palette) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .font(.system(size: 11))
                .foregroundStyle(palette.rowShortcutText)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(palette.rowText)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// The custom track replacing the stock `Slider`, matching mockups 1a/2a:
/// a base track, a diagonal-stripe hint over the unfilled boost zone (only
/// when `supportsBoost`), a solid nominal fill, a gradient boost fill, a
/// tick at the Nominal/Boost boundary, and a plain circular knob.
private struct BoostSlider: View {
    var percentage: Double
    var supportsBoost: Bool
    var palette: BrightnessMenuContent.Palette
    var onChange: (Double) -> Void

    private static let trackHeight: CGFloat = 6
    private static let knobDiameter: CGFloat = 18
    private static let rowHeight: CGFloat = 26

    private var effectiveMaximum: Double {
        BrightnessController.effectiveMaximum(supportsBoost: supportsBoost)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = percentage / effectiveMaximum
            let knobX = width * fraction
            // The boundary only exists partway across the track when Boost
            // is reachable; otherwise Nominal fills the entire track. Drawn
            // at the literal midpoint because the track always spans the
            // full 0...200 domain regardless of a personal Boost Ceiling
            // (ticket 02) — only how far the *fill* is allowed to travel
            // changes there, not where 100% sits on the track itself.
            let boundaryX = supportsBoost ? width / 2 : width
            let trackY = (Self.rowHeight - Self.trackHeight) / 2

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Self.trackHeight / 2)
                    .fill(palette.trackBackground)
                    .frame(width: width, height: Self.trackHeight)
                    .offset(y: trackY)

                if supportsBoost {
                    DiagonalStripes()
                        .stroke(palette.boostStripe, lineWidth: 3)
                        .frame(width: width - boundaryX, height: Self.trackHeight)
                        .offset(x: boundaryX, y: trackY)
                }

                RoundedRectangle(cornerRadius: Self.trackHeight / 2)
                    .fill(palette.nominalFill)
                    .frame(width: min(knobX, boundaryX), height: Self.trackHeight)
                    .offset(y: trackY)

                if supportsBoost && knobX > boundaryX {
                    Rectangle()
                        .fill(LinearGradient(colors: palette.boostGradient, startPoint: .leading, endPoint: .trailing))
                        .frame(width: knobX - boundaryX, height: Self.trackHeight)
                        .offset(x: boundaryX, y: trackY)
                }

                if supportsBoost {
                    Rectangle()
                        .fill(palette.boundaryTick)
                        .frame(width: 1.5, height: 14)
                        .offset(x: boundaryX - 0.75, y: Self.rowHeight / 2 - 7)
                }

                Circle()
                    .fill(palette.knobFill)
                    .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                    .shadow(color: palette.knobShadow, radius: 2, y: 1)
                    .offset(x: knobX - Self.knobDiameter / 2, y: (Self.rowHeight - Self.knobDiameter) / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clampedX = min(max(value.location.x, 0), width)
                        onChange((clampedX / width) * effectiveMaximum)
                    }
            )
        }
        .frame(height: Self.rowHeight)
    }
}

/// Repeating diagonal lines, matching the mockups' `repeating-linear-gradient`
/// stripe hint drawn over the not-yet-reached boost zone.
private struct DiagonalStripes: Shape {
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

extension BrightnessMenuContent {
    /// Every color the popover draws, resolved once per render from
    /// `colorScheme` — kept as plain stored properties (not a lookup
    /// function) so every subview reads the same resolved set.
    struct Palette {
        let primaryText: Color
        let secondaryText: Color
        let tertiaryText: Color
        let trackBackground: Color
        let nominalFill: Color
        let boostGradient: [Color]
        let boostStripe: Color
        let boundaryTick: Color
        let knobFill: Color
        let knobShadow: Color
        let boostBadgeBackground: Color
        let boostBadgeText: Color
        let quickSetBackground: Color
        let quickSetMaxBackground: Color
        let quickSetMaxText: Color
        let rowText: Color
        let rowShortcutText: Color
        let divider: Color

        init(colorScheme: ColorScheme) {
            switch colorScheme {
            case .dark:
                primaryText = .white
                secondaryText = Color.white.opacity(0.5)
                tertiaryText = Color.white.opacity(0.42)
                trackBackground = Color.white.opacity(0.16)
                nominalFill = .white
                boostGradient = [
                    Color(red: 1.0, green: 0.722, blue: 0.302),
                    Color(red: 1.0, green: 0.624, blue: 0.039)
                ]
                boostStripe = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.3)
                boundaryTick = Color.black.opacity(0.55)
                knobFill = .white
                knobShadow = Color.black.opacity(0.5)
                boostBadgeBackground = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.16)
                boostBadgeText = Color(red: 1.0, green: 0.624, blue: 0.039)
                quickSetBackground = Color.white.opacity(0.09)
                quickSetMaxBackground = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.18)
                quickSetMaxText = Color(red: 1.0, green: 0.722, blue: 0.302)
                rowText = Color.white.opacity(0.9)
                rowShortcutText = Color.white.opacity(0.35)
                divider = Color.white.opacity(0.12)
            case .light:
                fallthrough
            @unknown default:
                primaryText = Color(red: 0.114, green: 0.114, blue: 0.122)
                secondaryText = Color.black.opacity(0.45)
                tertiaryText = Color.black.opacity(0.4)
                trackBackground = Color.black.opacity(0.11)
                nominalFill = Color(red: 0.227, green: 0.227, blue: 0.235)
                boostGradient = [
                    Color(red: 1.0, green: 0.682, blue: 0.122),
                    Color(red: 0.941, green: 0.549, blue: 0.0)
                ]
                boostStripe = Color(red: 0.941, green: 0.549, blue: 0.0).opacity(0.28)
                boundaryTick = Color.black.opacity(0.28)
                knobFill = .white
                knobShadow = Color.black.opacity(0.28)
                boostBadgeBackground = Color(red: 0.941, green: 0.549, blue: 0.0).opacity(0.16)
                boostBadgeText = Color(red: 0.725, green: 0.416, blue: 0.0)
                quickSetBackground = Color.black.opacity(0.06)
                quickSetMaxBackground = Color(red: 0.941, green: 0.549, blue: 0.0).opacity(0.16)
                quickSetMaxText = Color(red: 0.725, green: 0.416, blue: 0.0)
                rowText = Color(red: 0.114, green: 0.114, blue: 0.122)
                rowShortcutText = Color.black.opacity(0.35)
                divider = Color.black.opacity(0.1)
            }
        }
    }
}
