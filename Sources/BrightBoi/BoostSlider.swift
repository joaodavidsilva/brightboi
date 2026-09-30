import SwiftUI

/// The custom track replacing the stock `Slider`: a base track, a diagonal
/// stripe hint over the Boost zone up to the Boost Ceiling, a dimmed tail
/// beyond the ceiling, a solid Nominal fill, a gradient Boost fill, small cuts
/// in the track at 100% and at the ceiling, and a circular knob.
///
/// Everything is drawn from `BoostSliderGeometry`, inside one capsule-clipped
/// track, so nothing pokes out of the track and the knob never leaves the
/// column. The knob is drawn at the level the controller actually applied,
/// not at the pointer, so a drag past the ceiling stops where the stripes end.
struct BoostSlider: View {
    var percentage: Double
    var supportsBoost: Bool
    /// The Boost Ceiling. Ignored when `supportsBoost` is false.
    var boostCeiling: Double = BrightnessController.maximumPercentage
    /// False while the controls do nothing (built-in display off): the slider
    /// then neither takes keys nor offers VoiceOver adjustment.
    var isEnabled: Bool = true
    var onChange: (Double) -> Void

    static let trackHeight: CGFloat = 6
    static let knobDiameter: CGFloat = 18
    static let rowHeight: CGFloat = 26

    private func geometry(width: CGFloat) -> BoostSliderGeometry {
        BoostSliderGeometry(
            width: width,
            knobDiameter: Self.knobDiameter,
            supportsBoost: supportsBoost,
            ceiling: boostCeiling
        )
    }

    private var reachableMaximum: Double {
        BoostSliderGeometry.reachableMaximum(supportsBoost: supportsBoost, ceiling: boostCeiling)
    }

    var body: some View {
        GeometryReader { proxy in
            let g = geometry(width: proxy.size.width)
            let boundary = g.trackOffset(for: BrightnessController.nominalCeilingPercentage)
            let ceiling = g.trackOffset(for: g.reachableMaximum)
            // The fills never run past the ceiling, even for a moment when
            // the ceiling is lowered under the current level.
            let knob = g.trackOffset(for: min(percentage, g.reachableMaximum))
            let trackY = (Self.rowHeight - Self.trackHeight) / 2

            ZStack(alignment: .topLeading) {
                track(geometry: g, boundary: boundary, ceiling: ceiling, knob: knob)
                    .frame(width: g.trackWidth, height: Self.trackHeight)
                    .compositingGroup()
                    .mask { TrackSegments(segments: g.segments).fill(Color.black) }
                    .clipShape(Capsule())
                    .offset(x: g.inset, y: trackY)

                Circle()
                    .fill(Color.sliderKnob)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                    .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                    .shadow(color: Color.sliderKnobShadow, radius: 2, y: 1)
                    .offset(x: g.x(for: min(percentage, g.reachableMaximum)) - Self.knobDiameter / 2, y: (Self.rowHeight - Self.knobDiameter) / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        onChange(g.percentage(atX: value.location.x))
                    }
            )
        }
        .frame(height: Self.rowHeight)
        // Focusable only for keyboard navigation, like a stock slider: it
        // neither takes focus nor draws a ring when the popover opens.
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.leftArrow, .downArrow, .rightArrow, .upArrow], phases: [.down, .repeat]) { press in
            guard isEnabled else { return .ignored }
            let steps = (press.key == .leftArrow || press.key == .downArrow) ? -1 : 1
            onChange(Self.steppedPercentage(from: percentage, steps: steps))
            return .handled
        }
        .help(supportsBoost ? "Boost Ceiling \(Int(boostCeiling))% — change it in Settings" : "")
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { percentage },
                    set: { onChange(Self.guardedTarget($0, from: percentage)) }
                ),
                in: 0...reachableMaximum,
                step: BrightnessController.percentageGranularity
            ) {
                Text("Brightness")
            }
            .disabled(!isEnabled)
            .accessibilityValue(Self.accessibilityValue(
                percentage: percentage,
                reachableMaximum: reachableMaximum,
                boostCeiling: supportsBoost ? boostCeiling : nil
            ))
            .accessibilityHint(supportsBoost && boostCeiling < BrightnessController.maximumPercentage
                ? "Change the Boost Ceiling in Settings."
                : "")
        }
    }

    /// Background, stripes and fills in track coordinates, before the cuts
    /// and the rounded ends are applied.
    private func track(geometry g: BoostSliderGeometry, boundary: CGFloat, ceiling: CGFloat, knob: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Rectangle().fill(Color.fillTrack).frame(width: ceiling)
                Rectangle().fill(Color.fillTrack).opacity(0.5).frame(width: max(g.trackWidth - ceiling, 0))
            }

            if g.supportsBoost {
                DiagonalStripes()
                    .stroke(Color.boostStripe, lineWidth: 2.5)
                    .frame(width: max(ceiling - boundary, 0), height: Self.trackHeight)
                    .clipped()
                    .offset(x: boundary)
            }

            Rectangle()
                .fill(Color.sliderNominal)
                .frame(width: min(knob, boundary))

            if g.supportsBoost && knob > boundary {
                Rectangle()
                    .fill(LinearGradient(colors: [Color.boostHighlight, Color.boost], startPoint: .leading, endPoint: .trailing))
                    .frame(width: knob - boundary)
                    .offset(x: boundary)
            }
        }
    }

    // MARK: Pure helpers

    /// The level a key press or an accessibility step asks for. Stepping
    /// down stops at one step above 0% instead of reaching it: 0% can switch
    /// the backlight off, and one arrow key should never do that. A drag can
    /// still reach 0%, and stepping up always works from there.
    static func guardedTarget(_ target: Double, from current: Double) -> Double {
        guard target < current else { return target }
        return max(target, min(BrightnessController.percentageGranularity, current))
    }

    static func steppedPercentage(from current: Double, steps: Int) -> Double {
        guardedTarget(current + Double(steps) * BrightnessController.percentageGranularity, from: current)
    }

    /// What VoiceOver reads for the slider.
    /// With Boost on and the ceiling below 200%, the value names the ceiling
    /// so it is heard together with the level, not only in the hint.
    static func accessibilityValue(percentage: Double, reachableMaximum: Double, boostCeiling: Double? = nil) -> String {
        var value = "\(Int(percentage.rounded())) percent"
        if percentage > BrightnessController.nominalCeilingPercentage { value += ", boosted" }
        if percentage >= reachableMaximum { value += ", maximum" }
        if let boostCeiling, boostCeiling < BrightnessController.maximumPercentage {
            value += ", Boost Ceiling \(Int(boostCeiling)) percent"
        }
        return value
    }
}

/// The solid stretches of the track, given in track coordinates; the gaps
/// between them are the cuts that mark 100% and the Boost Ceiling.
private struct TrackSegments: Shape {
    var segments: [ClosedRange<CGFloat>]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for segment in segments {
            path.addRect(CGRect(x: segment.lowerBound, y: rect.minY, width: segment.upperBound - segment.lowerBound, height: rect.height))
        }
        return path
    }
}

/// Repeating diagonal lines: the stripe hint drawn over the not-yet-reached
/// Boost zone.
struct DiagonalStripes: Shape {
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
