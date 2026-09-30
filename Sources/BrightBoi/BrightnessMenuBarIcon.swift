import AppKit
import SwiftUI

/// The menu bar glyph: a sun whose disc fills from the bottom in proportion
/// to `BrightnessController.State.iconFillFraction`, so it tracks the slider
/// live, with a small arrow badge once Boosted.
///
/// The glyph is drawn once into a single template `NSImage` and handed to the
/// status item's button. A template image is tinted by the menu bar itself,
/// so it stays legible on light and dark bars and against any wallpaper.
///
/// The rays and ring are always drawn at full strength: the item is the app's
/// only way in, and a faint outline at low brightness reads as disabled. Only
/// the disc fills. `iconFillFraction` spans the full 0...200% range on an XDR
/// panel (100% is half full) and 0...100% elsewhere, where the controller
/// divides by 100 instead. The badge is the cue for Boost that survives
/// template rendering, where a colour change would be flattened.
///
/// The image carries the spoken description, and the button the same text as
/// its accessibility label: "BrightBoi, brightness N percent", plus
/// ", boosted" once past 100%.
enum BrightnessMenuBarIcon {
    // MARK: - Pure helpers

    /// The canvas every glyph is drawn on, in points. The badge sits inside
    /// it, so nothing is clipped or widens the status item.
    static let canvasSize = CGSize(width: 20, height: 16)

    /// Where the disc lies in the sun symbol as drawn at `symbolPointSize`:
    /// the bottom of the ring is 0.266 of the canvas height above the canvas
    /// bottom, and the ring is 0.461 of the height tall. Measured on the
    /// rendered symbol, not derived from its metrics.
    static let symbolPointSize: CGFloat = 15
    /// Height of the disc's bottom edge above the canvas bottom, as a fraction of the canvas height.
    static let discBottom: CGFloat = 0.266
    /// Height of the disc, as a fraction of the canvas height.
    static let discHeight: CGFloat = 0.461

    /// Height of the fill mask, measured up from the canvas bottom, for a
    /// fill `fraction` (clamped to 0...1) on a canvas `canvasHeight` tall.
    /// At 0 the mask ends at the bottom of the disc, so nothing is filled;
    /// at 1 it ends at the top of the disc.
    static func fillMaskHeight(fraction: Double, canvasHeight: CGFloat) -> CGFloat {
        let clamped = CGFloat(min(max(fraction, 0), 1))
        return canvasHeight * (discBottom + discHeight * clamped)
    }

    /// How wide the fill's edge is softened, in points: one pixel on a
    /// Retina bar, so the edge pixel's coverage tracks the level exactly.
    static let fillEdgeSoftness: CGFloat = 0.5

    /// Gradient stops, top to bottom over the canvas, for the mask that keeps
    /// the fill below the level: transparent above it, opaque below. The soft
    /// edge slides from wholly below the disc at 0 to wholly above it at 1,
    /// so an empty glyph has no lit pixel and a full one no partly lit row,
    /// while every level in between still lands on its own sub-pixel row.
    static func fillMaskStops(fraction: Double, canvasHeight: CGFloat) -> [Gradient.Stop] {
        let edge = canvasHeight - fillMaskHeight(fraction: fraction, canvasHeight: canvasHeight)
        let clamped = CGFloat(min(max(fraction, 0), 1))
        let centre = edge + fillEdgeSoftness * (0.5 - clamped)
        let start = min(max((centre - fillEdgeSoftness / 2) / canvasHeight, 0), 1)
        let end = min(max((centre + fillEdgeSoftness / 2) / canvasHeight, 0), 1)
        return [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: start),
            .init(color: .black, location: end),
            .init(color: .black, location: 1)
        ]
    }

    /// What VoiceOver says for the status item.
    static func accessibilityLabel(percentage: Double, isBoosted: Bool) -> String {
        let level = "BrightBoi, brightness \(Int(percentage.rounded())) percent"
        return isBoosted ? level + ", boosted" : level
    }

    /// Distinct glyphs are cached by fraction in 2.5% steps, which is 5% of
    /// brightness on an XDR panel, and by Boost state: at most 41 x 2 images.
    private static func cacheKey(fraction: Double, isBoosted: Bool) -> Int {
        Int((min(max(fraction, 0), 1) * 40).rounded()) * 2 + (isBoosted ? 1 : 0)
    }

    /// Shared drawings by cache key. Only touched from `image`, on the main actor.
    @MainActor
    private static var cache: [Int: NSImage] = [:]

    /// The template image for a fill `fraction` and Boost state. Each call
    /// returns its own copy, so `description` can differ between callers
    /// while the drawing is shared.
    @MainActor
    static func image(fraction: Double, isBoosted: Bool, description: String? = nil) -> NSImage {
        let key = cacheKey(fraction: fraction, isBoosted: isBoosted)
        let base: NSImage
        if let cached = cache[key] {
            base = cached
        } else {
            base = render(fraction: Double(key / 2) / 40, isBoosted: isBoosted)
            cache[key] = base
        }
        // `copy()` keeps the representations, size and template flag.
        let image = (base.copy() as? NSImage) ?? base
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    @MainActor
    private static func render(fraction: Double, isBoosted: Bool) -> NSImage {
        let renderer = ImageRenderer(content: MenuBarGlyph(fraction: fraction, isBoosted: isBoosted))
        renderer.scale = 2
        let image: NSImage
        if let cgImage = renderer.cgImage {
            image = NSImage(cgImage: cgImage, size: canvasSize)
        } else {
            image = NSImage(size: canvasSize)
        }
        image.isTemplate = true
        return image
    }
}

/// The sun drawn on the fixed canvas, in black: a template image keeps only
/// its alpha, and the menu bar supplies the colour.
struct MenuBarGlyph: View {
    var fraction: Double
    var isBoosted: Bool

    private static let badgeKnockoutSize: CGFloat = 9
    private static let badgeSize: CGFloat = 7

    /// The sun sits this far left of the canvas centre, all the time, so the
    /// badge has room at the top right without covering the disc.
    private static let sunOffsetX: CGFloat = -1.5

    var body: some View {
        let canvas = BrightnessMenuBarIcon.canvasSize
        ZStack {
            Image(systemName: "sun.max")
                .frame(width: canvas.width, height: canvas.height)
            Image(systemName: "sun.max.fill")
                // Sized to the canvas first, so the mask's height is measured
                // against the same frame the disc constants were.
                .frame(width: canvas.width, height: canvas.height)
                .mask {
                    // A soft edge rather than a rectangle: SwiftUI snaps a
                    // rectangle's edges to whole device pixels, which made
                    // three levels in a row draw identically. A gradient is
                    // evaluated per pixel, so the edge row's coverage follows
                    // the exact fill level.
                    LinearGradient(
                        stops: BrightnessMenuBarIcon.fillMaskStops(
                            fraction: fraction,
                            canvasHeight: canvas.height
                        ),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: canvas.width, height: canvas.height)
                }
        }
        .font(.system(size: BrightnessMenuBarIcon.symbolPointSize))
        .offset(x: Self.sunOffsetX)
        .frame(width: canvas.width, height: canvas.height)
        .overlay(alignment: .topTrailing) {
            if isBoosted {
                // A gap is cut out of the sun around the badge so it never
                // touches a ray; the cut needs the compositing group below.
                ZStack {
                    Circle()
                        .frame(width: Self.badgeKnockoutSize, height: Self.badgeKnockoutSize)
                        .blendMode(.destinationOut)
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: Self.badgeSize, weight: .bold))
                }
            }
        }
        .foregroundStyle(.black)
        .compositingGroup()
    }
}
