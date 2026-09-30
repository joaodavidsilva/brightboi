import CoreGraphics

/// Where everything on the popover slider sits, as plain numbers.
///
/// The row is `width` wide and the knob's centre travels between one knob
/// radius from each end, so the knob never overhangs the column the rest of
/// the popover aligns to. The track itself spans exactly that travel. The
/// domain is always 0-200% when Boost is supported (100% at the exact
/// midpoint, however low the personal Boost Ceiling is set) and 0-100% when
/// it is not.
struct BoostSliderGeometry: Equatable {
    /// The whole row, in points.
    var width: CGFloat
    var knobDiameter: CGFloat
    var supportsBoost: Bool
    /// The Boost Ceiling in percent. Ignored without Boost.
    var ceiling: Double

    /// The width of the cut that marks 100% and the Boost Ceiling.
    static let gapWidth: CGFloat = 1.5

    init(width: CGFloat, knobDiameter: CGFloat, supportsBoost: Bool, ceiling: Double = BrightnessController.maximumPercentage) {
        self.width = width
        self.knobDiameter = knobDiameter
        self.supportsBoost = supportsBoost
        self.ceiling = ceiling
    }

    var inset: CGFloat { knobDiameter / 2 }

    /// The length of the track, which is also the knob's travel.
    var trackWidth: CGFloat { max(width - knobDiameter, 0) }

    var effectiveMaximum: Double {
        BrightnessController.effectiveMaximum(supportsBoost: supportsBoost)
    }

    /// The highest level the slider can reach: the Boost Ceiling with Boost,
    /// 100% without.
    var reachableMaximum: Double {
        Self.reachableMaximum(supportsBoost: supportsBoost, ceiling: ceiling)
    }

    static func reachableMaximum(supportsBoost: Bool, ceiling: Double) -> Double {
        let maximum = BrightnessController.effectiveMaximum(supportsBoost: supportsBoost)
        return supportsBoost
            ? min(max(ceiling, BrightnessController.nominalCeilingPercentage), maximum)
            : maximum
    }

    /// Distance from the start of the track for a level, in track coordinates.
    func trackOffset(for percentage: Double) -> CGFloat {
        let fraction = min(max(percentage / effectiveMaximum, 0), 1)
        return trackWidth * CGFloat(fraction)
    }

    /// The knob's centre for a level, in row coordinates.
    func x(for percentage: Double) -> CGFloat {
        inset + trackOffset(for: percentage)
    }

    /// The level under a pointer at `x` (row coordinates), clamped to the track.
    func percentage(atX x: CGFloat) -> Double {
        guard trackWidth > 0 else { return 0 }
        let fraction = min(max((x - inset) / trackWidth, 0), 1)
        return Double(fraction) * effectiveMaximum
    }

    /// Where Nominal ends and Boost begins, in row coordinates. The end of
    /// the track without Boost.
    var boundaryX: CGFloat { x(for: BrightnessController.nominalCeilingPercentage) }

    /// Where the Boost Ceiling falls, in row coordinates.
    var ceilingX: CGFloat { x(for: reachableMaximum) }

    /// Whether the Boost Ceiling falls short of the end of the track, leaving
    /// a tail the knob cannot reach.
    var hasUnreachableTail: Bool { supportsBoost && reachableMaximum < effectiveMaximum }

    /// The stretches of the track that stay solid, in track coordinates,
    /// separated by a `gapWidth` cut at 100% and, when there is an
    /// unreachable tail, at the Boost Ceiling.
    var segments: [ClosedRange<CGFloat>] {
        var cuts: [CGFloat] = []
        if supportsBoost { cuts.append(trackOffset(for: BrightnessController.nominalCeilingPercentage)) }
        if hasUnreachableTail { cuts.append(trackOffset(for: reachableMaximum)) }
        var result: [ClosedRange<CGFloat>] = []
        var start: CGFloat = 0
        for cut in cuts {
            result.append(start...max(start, cut - Self.gapWidth / 2))
            start = cut + Self.gapWidth / 2
        }
        result.append(start...max(start, trackWidth))
        return result
    }
}
