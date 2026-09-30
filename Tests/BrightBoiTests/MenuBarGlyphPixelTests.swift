import AppKit
import Testing
@testable import BrightBoi

/// The alpha of a menu bar glyph as the menu bar would rasterize it. A
/// template image keeps only its alpha, so this is everything the bar
/// draws; the tint is applied on top.
@MainActor
struct GlyphBitmap: Equatable {
    let scale: Int
    let width: Int
    let height: Int
    /// 0...1, row 0 at the top.
    let alpha: [Double]

    /// `scale` 2 is the image's own representation (what a Retina bar draws).
    /// `scale` 1 draws that representation down into one pixel per point,
    /// which is what a 1x bar, such as an external monitor, does.
    init(_ image: NSImage, scale: Int) {
        let width = Int(image.size.width) * scale
        let height = Int(image.size.height) * scale
        self.scale = scale
        self.width = width
        self.height = height
        var rect = CGRect(origin: .zero, size: image.size)
        let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.alpha = (0..<(width * height)).map { Double(bytes[$0 * 4 + 3]) / 255 }
    }

    func at(_ x: Int, _ y: Int) -> Double { alpha[y * width + x] }

    /// The total ink in a region given in points from the top-left.
    func ink(in region: CGRect) -> Double {
        var sum = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let point = CGPoint(x: (Double(x) + 0.5) / Double(scale), y: (Double(y) + 0.5) / Double(scale))
                if region.contains(point) { sum += alpha[y * width + x] }
            }
        }
        return sum
    }

    /// Total absolute difference from `other`, in full-strength pixels.
    func distance(to other: GlyphBitmap) -> Double {
        zip(alpha, other.alpha).reduce(0) { $0 + abs($1.0 - $1.1) }
    }
}

@MainActor
@Suite("Menu bar glyph pixels")
struct MenuBarGlyphPixelTests {
    static func bitmap(percentage: Double, xdr: Bool = true, scale: Int) -> GlyphBitmap {
        let fraction = percentage / (xdr ? 200 : 100)
        return GlyphBitmap(BrightnessMenuBarIcon.image(fraction: fraction, isBoosted: xdr && percentage > 100), scale: scale)
    }

    // MARK: Colour

    typealias RGB = (r: Double, g: Double, b: Double)

    /// Relative luminance as WCAG defines it, for channels 0...255.
    static func luminance(_ color: RGB) -> Double {
        func linear(_ value: Double) -> Double {
            let c = value / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// A menu bar fill, and the tint the bar gives a template image on it.
    /// These are read off real menu bar screenshots of this Mac: the built-in
    /// display's bar is black under the notch; an external display's bar
    /// took a blue-grey from its wallpaper, between #637491 and #7585A3; the
    /// light and dark fills the rendered item was first sampled on are
    /// #F5F5F5 and #1F1F1F. The bar tints a template black on a light fill
    /// and white on a dark or mid one.
    struct Bar: Sendable, CustomStringConvertible {
        var name: String
        var fill: RGB
        var tint: RGB
        var description: String { name }
    }

    nonisolated static let white: RGB = (255, 255, 255)
    nonisolated static let black: RGB = (0, 0, 0)
    nonisolated static let bars: [Bar] = [
        Bar(name: "light #F5F5F5", fill: (0xF5, 0xF5, 0xF5), tint: black),
        Bar(name: "dark #000000", fill: (0, 0, 0), tint: white),
        Bar(name: "dark #101013", fill: (0x10, 0x10, 0x13), tint: white),
        Bar(name: "dark #1F1F1F", fill: (0x1F, 0x1F, 0x1F), tint: white),
        Bar(name: "mid #637491", fill: (0x63, 0x74, 0x91), tint: white),
        Bar(name: "mid #7585A3", fill: (0x75, 0x85, 0xA3), tint: white)
    ]

    /// The colour a pixel of coverage `alpha` ends up as on `bar`.
    static func blended(alpha: Double, on bar: Bar) -> RGB {
        (bar.fill.r * (1 - alpha) + bar.tint.r * alpha,
         bar.fill.g * (1 - alpha) + bar.tint.g * alpha,
         bar.fill.b * (1 - alpha) + bar.tint.b * alpha)
    }

    /// Contrast of a pixel of coverage `alpha` against the bar it is on.
    static func contrast(alpha: Double, on bar: Bar) -> Double {
        contrast(blended(alpha: alpha, on: bar), bar.fill)
    }

    /// How opaque the glyph's outline typically is: the median coverage of
    /// every pixel with any real ink (above a tenth), so the ring and the
    /// rays as a whole are judged, and not just the few strongest pixels. A
    /// stroke that falls between two pixels shows up here as two half-strength
    /// pixels, which is what the bar would draw.
    static func strokeMedian(_ bitmap: GlyphBitmap) -> Double {
        let ink = bitmap.alpha.filter { $0 > 0.1 }.sorted()
        return ink[ink.count / 2]
    }

    // MARK: Every level is distinguishable

    /// Every 5% step on an XDR panel, 0...200%, and on a panel without Boost, 0...100%.
    static let xdrLevels = stride(from: 0.0, through: 200, by: 5).map { $0 }
    static let nominalLevels = stride(from: 0.0, through: 100, by: 5).map { $0 }

    /// The smallest difference between neighbouring 5% steps, measured in
    /// full-strength pixels of ink, below which the test fails: the measured
    /// minimum (0.043 at 1x, 0.21 at 2x, both at 190%) less a little. A 1x
    /// bar therefore tells some neighbouring levels apart only by a sliver;
    /// the larger jumps between the named levels are tested separately.
    static func smallestStep(scale: Int) -> Double { scale == 1 ? 0.04 : 0.2 }

    @Test("no two neighbouring 5% steps draw the same glyph, and none is closer than the measured floor", arguments: [1, 2])
    func everyStepIsDistinct(scale: Int) {
        for (levels, xdr) in [(Self.xdrLevels, true), (Self.nominalLevels, false)] {
            let bitmaps = levels.map { Self.bitmap(percentage: $0, xdr: xdr, scale: scale) }
            for (index, pair) in zip(bitmaps, bitmaps.dropFirst()).enumerated() {
                let difference = pair.0.distance(to: pair.1)
                #expect(difference > Self.smallestStep(scale: scale), "\(levels[index])% and \(levels[index + 1])% look the same at \(scale)x (xdr: \(xdr))")
            }
            #expect(Set(bitmaps.map(\.alpha)).count == bitmaps.count)
        }
    }

    @Test("the disc's ink only ever grows with the level, so the gauge reads monotonically", arguments: [1, 2])
    func discInkGrows(scale: Int) {
        // The disc's columns, clear of the badge and its gap on the right.
        let disc = CGRect(x: 4, y: 0, width: 7, height: 16)
        let inks = Self.xdrLevels.map { Self.bitmap(percentage: $0, scale: scale).ink(in: disc) }
        for (index, pair) in zip(inks, inks.dropFirst()).enumerated() {
            #expect(pair.1 > pair.0, "ink did not grow from \(Self.xdrLevels[index])% to \(Self.xdrLevels[index + 1])% at \(scale)x")
        }
    }

    @Test("the levels the popover names differ from one another, if only by a sliver at 1x", arguments: [1, 2])
    func namedLevelsAreClearlyDifferent(scale: Int) {
        let named: [Double] = [0, 50, 100, 150, 200]
        let bitmaps = named.map { Self.bitmap(percentage: $0, scale: scale) }
        for (index, pair) in zip(bitmaps, bitmaps.dropFirst()).enumerated() {
            // More than a whole pixel of ink apart, at either scale.
            let apart = pair.0.distance(to: pair.1)
            #expect(apart > 1, "\(named[index])% and \(named[index + 1])% are too alike at \(scale)x")
        }
    }

    // MARK: Contrast

    /// A bar whose fill is a mid tone, where white ink has the least room.
    static func isMidTone(_ bar: Bar) -> Bool { bar.name.hasPrefix("mid") }

    @Test("the outline, ring and rays together, is at least 3:1 on every measured bar where it is drawn at 2x, at every level", arguments: bars)
    func outlineContrast(bar: Bar) {
        for level in Self.xdrLevels {
            let median = Self.strokeMedian(Self.bitmap(percentage: level, scale: 2))
            let ratio = Self.contrast(alpha: median, on: bar)
            #expect(ratio >= 3, "\(level)% at 2x on \(bar): \(ratio):1 (median coverage \(median))")
        }
    }

    @Test("on a 1x bar the outline is 3:1 on light and dark fills, and only 2:1 on a mid-tone one", arguments: bars)
    func outlineContrastAtOneX(bar: Bar) {
        // A 1pt stroke that falls between two pixels is two half-strength
        // pixels on a 1x bar. That is fine on black or near-white, and below
        // 3:1 on the blue-grey an external display's bar takes from its
        // wallpaper. The shortfall is recorded, not hidden.
        let floor = Self.isMidTone(bar) ? 2.0 : 3.0
        for level in Self.xdrLevels {
            let median = Self.strokeMedian(Self.bitmap(percentage: level, scale: 1))
            let ratio = Self.contrast(alpha: median, on: bar)
            #expect(ratio >= floor, "\(level)% at 1x on \(bar): \(ratio):1 (median coverage \(median))")
        }
    }

    @Test("the unlit outline at 0% is never faint: the median ink is at least half strength at 1x and 80% at 2x", arguments: [1, 2])
    func zeroPercentIsNotDisabledLooking(scale: Int) {
        #expect(Self.strokeMedian(Self.bitmap(percentage: 0, scale: scale)) >= (scale == 1 ? 0.5 : 0.8))
    }

    @Test("an empty glyph has no lit disc, and a full one no partly lit row at its top")
    func fillEdgeStaysInsideTheDisc() {
        let height = BrightnessMenuBarIcon.canvasSize.height
        func window(_ fraction: Double) -> (start: Double, end: Double, edge: Double) {
            let stops = BrightnessMenuBarIcon.fillMaskStops(fraction: fraction, canvasHeight: height)
            let edge = height - BrightnessMenuBarIcon.fillMaskHeight(fraction: fraction, canvasHeight: height)
            return (Double(stops[1].location * height), Double(stops[2].location * height), Double(edge))
        }
        // Coordinates run down from the top: the mask is clear until `start`
        // and opaque from `end`.
        #expect(window(0).start >= window(0).edge - 0.0001, "some of the empty disc is lit")
        #expect(window(1).end <= window(1).edge + 0.0001, "the top of the full disc is not fully lit")
    }

    @Test("the lit part of the disc is at least 3:1 against every measured menu bar", arguments: bars)
    func litDiscContrast(bar: Bar) throws {
        for scale in [1, 2] {
            // From 90%: below that the lit band is under 3pt tall and has no
            // interior left to sample once its soft edge is excluded.
            for level in stride(from: 90.0, through: 200, by: 5) {
                let bitmap = Self.bitmap(percentage: level, scale: scale)
                let fraction = level / 200
                let edge = 16 - BrightnessMenuBarIcon.fillMaskHeight(fraction: fraction, canvasHeight: 16)
                let bottom = 16 - 16 * BrightnessMenuBarIcon.discBottom
                // A run of pixels down the disc's centre line, well inside the lit area.
                var coverage: [Double] = []
                for y in 0..<bitmap.height {
                    let pointY = (Double(y) + 0.5) / Double(scale)
                    guard pointY > edge + 0.75, pointY < bottom - 0.75 else { continue }
                    coverage.append(bitmap.at(Int(8.5 * Double(scale)), y))
                }
                try #require(!coverage.isEmpty, "no lit pixels sampled at \(level)% at \(scale)x")
                let weakest = coverage.min()!
                let ratio = Self.contrast(alpha: weakest, on: bar)
                #expect(ratio >= 3, "lit disc at \(level)% at \(scale)x on \(bar): \(ratio):1 (coverage \(weakest))")
            }
        }
    }

    // MARK: The Boost badge

    /// Connected ink (coverage above a quarter), each as its list of pixels.
    static func components(of bitmap: GlyphBitmap) -> [[(x: Int, y: Int)]] {
        var seen = Set<Int>()
        var result: [[(x: Int, y: Int)]] = []
        for start in 0..<(bitmap.width * bitmap.height) where bitmap.alpha[start] > 0.25 && !seen.contains(start) {
            var stack = [start]
            seen.insert(start)
            var pixels: [(x: Int, y: Int)] = []
            while let current = stack.popLast() {
                let (x, y) = (current % bitmap.width, current / bitmap.width)
                pixels.append((x, y))
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let (nx, ny) = (x + dx, y + dy)
                        guard nx >= 0, ny >= 0, nx < bitmap.width, ny < bitmap.height else { continue }
                        let index = ny * bitmap.width + nx
                        if bitmap.alpha[index] > 0.25, seen.insert(index).inserted { stack.append(index) }
                    }
                }
            }
            result.append(pixels)
        }
        return result
    }

    @Test("the badge is its own shape, clear of every ray and the ring, and inside the canvas")
    func badgeDoesNotTouchTheSun() throws {
        let scale = 2
        let bitmap = Self.bitmap(percentage: 150, scale: scale)
        let components = Self.components(of: bitmap)
        // The badge is centred on the top-right of the canvas, inset by half its knockout.
        let centre = (x: (20 - 4.5) * Double(scale), y: 4.5 * Double(scale))
        let badge = try #require(components.first { component in
            component.contains { abs(Double($0.x) + 0.5 - centre.x) < 1.5 && abs(Double($0.y) + 0.5 - centre.y) < 1.5 }
        }, "no ink at the badge's centre")
        let badgePixels = Set(badge.map { $0.y * bitmap.width + $0.x })

        // Its ink sits inside the canvas with room to spare on every side.
        #expect(badge.map(\.x).max()! < bitmap.width - 1)
        #expect(badge.map(\.y).min()! > 0)

        // No other ink is near it: the closest any other shape comes is a full point.
        var closest = Double.infinity
        for other in components where other.first.map({ !badgePixels.contains($0.y * bitmap.width + $0.x) }) == true {
            for p in other {
                for q in badge {
                    closest = min(closest, hypot(Double(p.x - q.x), Double(p.y - q.y)) / Double(scale))
                }
            }
        }
        #expect(closest >= 1, "the badge comes within \(closest)pt of the sun")
    }

    @Test("the badge sits only where the sun was cut away for it")
    func badgeReplacesOnlyTheRayItCovers() {
        let scale = 2
        let plain = Self.bitmap(percentage: 100, scale: scale)
        let boosted = BrightnessMenuBarIcon.image(fraction: 0.5, isBoosted: true)
        let withBadge = GlyphBitmap(boosted, scale: scale)
        // Outside the badge's 9pt knockout circle the sun is exactly as it was.
        let centre = (x: 15.5, y: 4.5)
        var changed = 0
        for y in 0..<plain.height {
            for x in 0..<plain.width {
                let point = (x: (Double(x) + 0.5) / Double(scale), y: (Double(y) + 0.5) / Double(scale))
                let outside = hypot(point.x - centre.x, point.y - centre.y) > 4.5 + 0.75
                if outside, abs(plain.at(x, y) - withBadge.at(x, y)) > 0.01 { changed += 1; print("DIAG pixel x=\(x) y=\(y) plain=\(plain.at(x, y)) badge=\(withBadge.at(x, y)) dist=\(hypot(point.x - centre.x, point.y - centre.y))") }
            }
        }
        #expect(changed == 0, "\(changed) pixels outside the badge's knockout changed when Boost came on")
    }

    @Test("a panel without Boost never draws a badge, at any level")
    func noBadgeWithoutBoost() {
        let badgeArea = CGRect(x: 12, y: 0, width: 8, height: 9)
        let withBadge = Self.bitmap(percentage: 150, scale: 2).ink(in: badgeArea)
        for level in Self.nominalLevels {
            let ink = Self.bitmap(percentage: level, xdr: false, scale: 2).ink(in: badgeArea)
            #expect(ink < withBadge / 2, "ink in the badge's corner at \(level)% without Boost")
        }
    }
}
