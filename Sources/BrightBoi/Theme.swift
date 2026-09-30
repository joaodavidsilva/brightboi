import AppKit
import SwiftUI

// The one place BrightBoi's colours, type ramp, radii and pill-button
// behaviour are defined, shared by the popover, Settings, onboarding, the
// donation window and the HUD.
//
// Colours are dynamic: each token carries a light, a dark and an Increase
// Contrast value, and resolves against the appearance it is drawn in. They
// are explicit values rather than the system label colours on purpose. Those
// measure worse against the popover and Settings backgrounds (the tertiary
// label colour is below 2:1 on white), and several BrightBoi colours, the
// boost amber above all, genuinely differ between light and dark instead of
// inverting.

// MARK: - Colour tokens

/// An sRGB colour as plain numbers, so dynamic-colour closures can capture it
/// without carrying an `NSColor` across isolation boundaries.
struct Shade: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`, optionally translucent.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func white(_ alpha: Double = 1) -> Shade { Shade(red: 1, green: 1, blue: 1, alpha: alpha) }
    static func black(_ alpha: Double = 1) -> Shade { Shade(red: 0, green: 0, blue: 0, alpha: alpha) }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// The four looks a token can have. Increase Contrast falls back to the plain
/// light or dark value when a token doesn't define its own.
struct ThemeValues: Sendable {
    var light: Shade
    var dark: Shade
    var lightIncreased: Shade?
    var darkIncreased: Shade?

    init(light: Shade, dark: Shade, lightIncreased: Shade? = nil, darkIncreased: Shade? = nil) {
        self.light = light
        self.dark = dark
        self.lightIncreased = lightIncreased
        self.darkIncreased = darkIncreased
    }

    /// The same value in both schemes.
    init(_ both: Shade, increased: Shade? = nil) {
        self.init(light: both, dark: both, lightIncreased: increased, darkIncreased: increased)
    }

    /// The Increase Contrast appearances under both spellings of their names.
    /// Current SDKs spell the Swift constants differently from the names the
    /// high-contrast appearances are registered under, so matching only the
    /// constants would miss them on some systems.
    private static let lightIncreasedNames: [NSAppearance.Name] = [
        .accessibilityHighContrastAqua,
        NSAppearance.Name("NSAppearanceNameAccessibilityHighContrastAqua")
    ]
    private static let darkIncreasedNames: [NSAppearance.Name] = [
        .accessibilityHighContrastDarkAqua,
        NSAppearance.Name("NSAppearanceNameAccessibilityHighContrastDarkAqua")
    ]

    func shade(for appearance: NSAppearance) -> Shade {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua] + Self.lightIncreasedNames + Self.darkIncreasedNames)
        let isDark = match == .darkAqua || match.map(Self.darkIncreasedNames.contains) == true
        let increased = Theme.increaseContrastOverride
            ?? match.map { Self.lightIncreasedNames.contains($0) || Self.darkIncreasedNames.contains($0) }
            ?? false
        switch (isDark, increased) {
        case (true, true): return darkIncreased ?? dark
        case (true, false): return dark
        case (false, true): return lightIncreased ?? light
        case (false, false): return light
        }
    }

    var nsColor: NSColor {
        NSColor(name: nil) { appearance in shade(for: appearance).nsColor }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// Every colour token with its values, kept in one table so the views and the
/// tests read the same numbers.
enum Theme {
    /// Forces the Increase Contrast look on (or off) regardless of the
    /// system setting. A seam for tests and design renders, which cannot flip
    /// the system preference; the app never sets it. Unsynchronised: set it before any view is
    /// built and reset it when done.
    nonisolated(unsafe) static var increaseContrastOverride: Bool?

    // Text
    static let textPrimary = ThemeValues(
        light: Shade(hex: 0x1D1D1F), dark: .white(),
        lightIncreased: .black(), darkIncreased: .white()
    )
    static let textSecondary = ThemeValues(light: .black(0.65), dark: .white(0.65), lightIncreased: .black(0.8), darkIncreased: .white(0.8))
    static let textTertiary = ThemeValues(light: .black(0.6), dark: .white(0.58), lightIncreased: .black(0.72), darkIncreased: .white(0.72))
    /// Row titles and banner text: a touch softer than primary in dark.
    static let textRow = ThemeValues(
        light: Shade(hex: 0x1D1D1F), dark: .white(0.9),
        lightIncreased: .black(), darkIncreased: .white()
    )

    // Fills
    static let fillTrack = ThemeValues(light: .black(0.11), dark: .white(0.16), lightIncreased: .black(0.3), darkIncreased: .white(0.35))
    static let fillGrouped = ThemeValues(light: .black(0.06), dark: .white(0.09), lightIncreased: .black(0.1), darkIncreased: .white(0.15))
    /// Buttons that sit on the window or on a grouped row.
    static let fillControl = ThemeValues(light: .black(0.1), dark: .white(0.14), lightIncreased: .black(0.16), darkIncreased: .white(0.22))
    static let divider = ThemeValues(light: .black(0.1), dark: .white(0.12), lightIncreased: .black(0.3), darkIncreased: .white(0.3))
    /// The background of onboarding and the donation window.
    static let surfaceWindow = ThemeValues(light: Shade(hex: 0xF2F2F4), dark: Shade(hex: 0x1F1F22))

    // Slider and meter
    static let sliderNominal = ThemeValues(light: Shade(hex: 0x3A3A3C), dark: .white())
    static let sliderKnob = ThemeValues(.white())
    static let sliderKnobShadow = ThemeValues(light: .black(0.28), dark: .black(0.5))
    static let pageDotActive = ThemeValues(light: .black(0.6), dark: .white(0.85))
    static let pageDotInactive = ThemeValues(light: .black(0.16), dark: .white(0.22), lightIncreased: .black(0.35), darkIncreased: .white(0.4))

    // Boost amber
    /// Fills, tints, glyphs and the slider tint.
    static let boost = ThemeValues(light: Shade(hex: 0xF08C00), dark: Shade(hex: 0xFF9F0A))
    /// The start of the boost gradient.
    static let boostHighlight = ThemeValues(light: Shade(hex: 0xFFAE1F), dark: Shade(hex: 0xFFB84D))
    /// Text on a boost tint. Light #8A4F00 is about 4.9:1 on its tint.
    static let boostText = ThemeValues(
        light: Shade(hex: 0x8A4F00), dark: Shade(hex: 0xFFB84D),
        lightIncreased: Shade(hex: 0x6E3F00), darkIncreased: Shade(hex: 0xFFCE7A)
    )
    static let boostFill = ThemeValues(
        light: Shade(hex: 0xF08C00, alpha: 0.16), dark: Shade(hex: 0xFF9F0A, alpha: 0.16),
        lightIncreased: Shade(hex: 0xF08C00, alpha: 0.26), darkIncreased: Shade(hex: 0xFF9F0A, alpha: 0.28)
    )
    static let boostStripe = ThemeValues(
        light: Shade(hex: 0xF08C00, alpha: 0.28), dark: Shade(hex: 0xFF9F0A, alpha: 0.3),
        lightIncreased: Shade(hex: 0xF08C00, alpha: 0.45), darkIncreased: Shade(hex: 0xFF9F0A, alpha: 0.5)
    )
    /// Lit Boost segments and the boosted glyph in the key-press HUD. Darker
    /// than `boost` in light mode, so lit and unlit Boost segments stay
    /// distinguishable on the HUD's light material.
    static let hudBoost = ThemeValues(
        light: Shade(hex: 0x9A5800), dark: Shade(hex: 0xFF9F0A),
        lightIncreased: Shade(hex: 0x7A4500), darkIncreased: Shade(hex: 0xFFD79A)
    )
    /// The sun in onboarding and the donation window, the brand glyph.
    static let sunGlyph = ThemeValues(light: Shade(hex: 0xE8890C), dark: Shade(hex: 0xFFCE7A))
    /// Sun-coloured text, where the glyph colour is too light to read. #8F5200 is 4.9:1 on an onboarding row.
    static let sunText = ThemeValues(light: Shade(hex: 0x8F5200), dark: Shade(hex: 0xFFCE7A), lightIncreased: Shade(hex: 0x7A4500))

    // Accent and status
    /// Filled accent buttons; white text on it is 4.70:1.
    static let accentButton = ThemeValues(Shade(hex: 0x0071E3), increased: Shade(hex: 0x0058B8))
    /// Accent-coloured text on a window or grouped row.
    static let accentText = ThemeValues(
        light: Shade(hex: 0x0062C4), dark: Shade(hex: 0x5AA9FF),
        lightIncreased: Shade(hex: 0x004A99), darkIncreased: Shade(hex: 0x8CC4FF)
    )
    /// Text explaining why a recorded shortcut was refused.
    static let recorderError = ThemeValues(
        light: Shade(hex: 0xC4001A), dark: Shade(hex: 0xFF9C96),
        lightIncreased: Shade(hex: 0xA80016), darkIncreased: Shade(hex: 0xFFD6D2)
    )
}

extension Color {
    static let textPrimary = Theme.textPrimary.color
    static let textSecondary = Theme.textSecondary.color
    static let textTertiary = Theme.textTertiary.color
    static let textRow = Theme.textRow.color

    static let fillTrack = Theme.fillTrack.color
    static let fillGrouped = Theme.fillGrouped.color
    static let fillControl = Theme.fillControl.color
    static let divider = Theme.divider.color
    static let surfaceWindow = Theme.surfaceWindow.color

    static let sliderNominal = Theme.sliderNominal.color
    static let sliderKnob = Theme.sliderKnob.color
    static let sliderKnobShadow = Theme.sliderKnobShadow.color
    static let pageDotActive = Theme.pageDotActive.color
    static let pageDotInactive = Theme.pageDotInactive.color

    static let boost = Theme.boost.color
    static let boostHighlight = Theme.boostHighlight.color
    static let boostText = Theme.boostText.color
    static let boostFill = Theme.boostFill.color
    static let boostStripe = Theme.boostStripe.color
    static let hudBoost = Theme.hudBoost.color
    static let sunGlyph = Theme.sunGlyph.color
    static let sunText = Theme.sunText.color

    static let accentButton = Theme.accentButton.color
    static let accentText = Theme.accentText.color
    static let recorderError = Theme.recorderError.color
}

// Settings has its own names for the roles it shares with other surfaces, so
// it never borrows a popover role by accident.
extension Color {
    /// The rounded container behind a group of Settings rows.
    static let settingsGroupFill = Color.fillGrouped
    /// The line between rows inside a Settings group.
    static let settingsGroupDivider = Color.divider
    /// The small uppercase heading above a Settings group.
    static let settingsSectionHeader = Color.textTertiary
}

// MARK: - Type ramp

extension Theme {
    /// The named text styles. Sizes are points; macOS text styles are fixed
    /// sizes, so `body` is 13, `callout` 12, `subheadline` 11 and `caption` 10.
    enum Typography {
        /// The popover's brightness readout.
        static let display = Font.system(size: 34, weight: .semibold).monospacedDigit()
        /// Every window title.
        static let title = Font.system(size: 20, weight: .semibold)
        /// Running text and rows.
        static let body = Font.body
        /// Full-width buttons.
        static let buttonLarge = Font.body.weight(.medium)
        /// Small buttons, pills and quick-set labels.
        static let control = Font.callout.weight(.medium)
        static let callout = Font.callout
        /// Subtitles, notices, footnotes and captions under a control.
        static let secondary = Font.subheadline
        static let secondaryMedium = Font.subheadline.weight(.medium)
        /// Range captions and badges.
        static let caption = Font.system(size: 10)
        static let badge = Font.system(size: 10, weight: .semibold)
        /// A highlighted value beside a control, such as the Boost Ceiling.
        static let value = Font.system(size: 15, weight: .semibold).monospacedDigit()
        /// Section headings in Settings.
        static let sectionHeader = Font.subheadline.weight(.semibold)
        /// The percentage under the key-press HUD meter.
        static let hudReadout = Font.system(size: 13, weight: .semibold).monospacedDigit()
        /// The Buy Me a Coffee button keeps its brand weight.
        static let brandCTA = Font.system(size: 13.5, weight: .bold)
    }

    /// Sizes of icons, which are drawings rather than text.
    enum GlyphSize {
        static let inline: CGFloat = 11
        static let header: CGFloat = 12
        static let donation: CGFloat = 26
        static let onboarding: CGFloat = 40
        static let hud: CGFloat = 44
        /// The Boost arrow on the HUD glyph.
        static let hudBadge: CGFloat = 16
    }

    enum Radius {
        static let badge: CGFloat = 4
        /// Recorder pill, Settings buttons, Grant.
        static let control: CGFloat = 6
        /// Full-width buttons and the quick-set row.
        static let button: CGFloat = 8
        /// Grouped containers and advisories.
        static let card: CGFloat = 10
        static let hud: CGFloat = 20
    }
}

// MARK: - Increase Contrast borders and dividers

extension Theme {
    /// Whether geometry (borders, line widths) should use its Increase
    /// Contrast form, given the environment's contrast.
    static func isIncreasedContrast(_ contrast: ColorSchemeContrast) -> Bool {
        increaseContrastOverride ?? (contrast == .increased)
    }
}

/// Adds a 1pt border in the primary text colour at half strength while
/// Increase Contrast is on, so fills that are only a few percent off the
/// background still read as controls. Does nothing otherwise.
struct ContrastBorder: ViewModifier {
    var cornerRadius: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if Theme.isIncreasedContrast(contrast) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.textPrimary.opacity(0.5), lineWidth: 1)
            }
        }
    }
}

extension View {
    func contrastBorder(cornerRadius: CGFloat) -> some View {
        modifier(ContrastBorder(cornerRadius: cornerRadius))
    }
}

/// A hairline between rows: 0.5pt, and 1pt under Increase Contrast.
struct ThemeDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(Color.divider)
            .frame(height: Self.thickness(increased: Theme.isIncreasedContrast(contrast)))
    }

    nonisolated static func thickness(increased: Bool) -> CGFloat { increased ? 1 : 0.5 }
}

// MARK: - Pill buttons

/// A button whose whole drawn pill is clickable. The padding, fill and hit
/// shape live inside the label, so the area that looks like the button is the
/// area that responds; padding applied outside a plain button only draws.
struct PillButtonStyle: ButtonStyle {
    var fill: Color = .fillControl
    var foreground: Color = .textRow
    var cornerRadius: CGFloat = Theme.Radius.control
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 4
    /// Stretches the pill across the available width.
    var fillsWidth = false
    /// Draws the Increase Contrast border; off for borderless text buttons.
    var bordered = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .foregroundStyle(foreground)
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius))
            .modifier(OptionalContrastBorder(cornerRadius: cornerRadius, enabled: bordered))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct OptionalContrastBorder: ViewModifier {
    var cornerRadius: CGFloat
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.contrastBorder(cornerRadius: cornerRadius)
        } else {
            content
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    /// A text-only button with a padded hit area and no fill.
    static func link(foreground: Color, horizontalPadding: CGFloat = 8, verticalPadding: CGFloat = 4) -> PillButtonStyle {
        PillButtonStyle(
            fill: .clear, foreground: foreground,
            horizontalPadding: horizontalPadding, verticalPadding: verticalPadding,
            bordered: false
        )
    }
}
