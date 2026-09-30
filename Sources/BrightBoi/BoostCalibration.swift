import CoreGraphics
import Foundation

/// How the display's transfer table relates to light output, which decides
/// what table factor produces a given brightness ratio.
///
/// The Boost range is expressed as a *luminance ratio* against Nominal 100%
/// (2.0 means twice as bright). If the table scales linear light, the table
/// factor is that ratio. If it scales the gamma-encoded signal, the factor is
/// the ratio raised to 1/gamma, because the panel then raises the signal to
/// about the 2.2 power.
///
/// Which one macOS applies has not been measured, so `assumed` stays
/// `.linear`. `docs/brightness-api-research.md` describes the step-wedge test
/// that settles it; changing `assumed` afterwards is the only edit needed.
enum GammaDomain: Equatable {
    case linear
    case encoded(gamma: Double)

    /// What the engine uses. The effective-factor clamp to the EDR headroom
    /// assumes the same domain.
    static let assumed: GammaDomain = .linear

    /// The table factor that produces `ratio` times the luminance.
    func tableFactor(forLuminanceRatio ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 1 }
        switch self {
        case .linear: return ratio
        case .encoded(let gamma): return pow(ratio, 1 / gamma)
        }
    }

    /// The luminance ratio a table factor produces. The inverse of
    /// `tableFactor(forLuminanceRatio:)`.
    func luminanceRatio(forTableFactor factor: Double) -> Double {
        guard factor.isFinite, factor > 0 else { return 1 }
        switch self {
        case .linear: return factor
        case .encoded(let gamma): return pow(factor, gamma)
        }
    }
}

/// How the 100-200% slider range maps onto the luminance ratio. Kept as an
/// enum so the curve can be switched once the step is judged by eye; only
/// `active` changes.
enum BoostCurve: Equatable {
    /// Even steps in luminance: +5% of the ratio range per 5% of slider.
    case linear
    /// Even steps in perceived change: each slider step multiplies the
    /// luminance by the same amount, so the first press above 100% and the
    /// last one feel alike.
    case geometric

    static let active: BoostCurve = .linear

    /// The luminance ratio at `fraction` (0...1) of the way through the Boost
    /// range, for a range that ends at `ceilingRatio`. Both curves hit 1.0 at
    /// 0 and `ceilingRatio` at 1.
    func luminanceRatio(forBoostFraction fraction: Double, ceilingRatio: Double) -> Double {
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        let ceiling = max(ceilingRatio.isFinite ? ceilingRatio : 1, 1)
        switch self {
        case .linear: return 1 + f * (ceiling - 1)
        case .geometric: return pow(ceiling, f)
        }
    }
}

/// The per-panel Boost ceiling and the mapping from the slider to the table
/// factor that is written.
enum BoostCalibration {
    /// The largest luminance ratio Boost ever asks for: 2.0 is 1000 nits on a
    /// panel whose Nominal 100% is 500 nits.
    static let maximumRatio = 2.0

    /// The share of the panel's unthrottled EDR headroom that 200% may use.
    /// The panel's peak (1600 nits) is 3.2 times a 500-nit Nominal 100%, and
    /// the sustained full-screen rating (1000 nits) is 62.5% of that peak.
    /// Expressed against the headroom rather than in nits, so a panel with a
    /// brighter Nominal 100% and so less headroom gets a lower ceiling:
    /// 1000 nits divided by the panel's own SDR white.
    static let sustainedShareOfHeadroom = 0.625

    /// The luminance ratio 200% maps to: `maximumRatio`, or less when the
    /// panel's headroom leaves no room for it. `observedHeadroom` is the
    /// largest unthrottled headroom seen (`ObservedHeadroom`); `nil` while
    /// it is not known yet gives the full ratio, and the live clamp to the
    /// granted headroom still prevents clipping in the meantime.
    static func ceilingRatio(observedHeadroom: CGFloat?) -> Double {
        guard let observedHeadroom, observedHeadroom.isFinite, observedHeadroom > 1 else { return maximumRatio }
        return min(maximumRatio, max(1, sustainedShareOfHeadroom * Double(observedHeadroom)))
    }

    /// The table factor for `fraction` (0...1) of the Boost range.
    static func tableFactor(
        forBoostFraction fraction: Double,
        observedHeadroom: CGFloat?,
        curve: BoostCurve = .active,
        domain: GammaDomain = .assumed
    ) -> CGFloat {
        let ratio = curve.luminanceRatio(forBoostFraction: fraction, ceilingRatio: ceilingRatio(observedHeadroom: observedHeadroom))
        return CGFloat(max(1, domain.tableFactor(forLuminanceRatio: ratio)))
    }
}
