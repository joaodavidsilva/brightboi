import AppKit
import SwiftUI
import Testing
@testable import BrightBoi

/// The colour tokens: exact values per appearance, and WCAG contrast of every
/// text role against the background it is really drawn on.
@Suite("Theme")
struct ThemeTests {
    private enum Look: CaseIterable {
        case light, dark, lightIncreased, darkIncreased

        /// The Increase Contrast appearances are made under the names they
        /// are registered with; the SDK's Swift constants for them do not
        /// produce a high-contrast appearance on every system.
        var appearanceName: NSAppearance.Name {
            switch self {
            case .light: .aqua
            case .dark: .darkAqua
            case .lightIncreased: NSAppearance.Name("NSAppearanceNameAccessibilityHighContrastAqua")
            case .darkIncreased: NSAppearance.Name("NSAppearanceNameAccessibilityHighContrastDarkAqua")
            }
        }

        var isDark: Bool { self == .dark || self == .darkIncreased }
        var isIncreased: Bool { self == .lightIncreased || self == .darkIncreased }
        var appearance: NSAppearance { NSAppearance(named: appearanceName)! }
    }

    // MARK: Helpers

    /// What a token resolves to when drawn in `look`, read back through
    /// AppKit's own dynamic-colour machinery rather than the table.
    private func resolved(_ values: ThemeValues, _ look: Look) -> Shade {
        var shade = Shade.black()
        look.appearance.performAsCurrentDrawingAppearance {
            let color = values.nsColor.usingColorSpace(.sRGB)!
            shade = Shade(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent), alpha: Double(color.alphaComponent))
        }
        return shade
    }

    /// `top` painted over an opaque `bottom`.
    private func composite(_ top: Shade, over bottom: Shade) -> Shade {
        let a = top.alpha
        return Shade(
            red: top.red * a + bottom.red * (1 - a),
            green: top.green * a + bottom.green * (1 - a),
            blue: top.blue * a + bottom.blue * (1 - a)
        )
    }

    private func luminance(_ shade: Shade) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(shade.red) + 0.7152 * linear(shade.green) + 0.0722 * linear(shade.blue)
    }

    /// WCAG contrast ratio of `text` (alpha allowed) drawn over opaque `background`.
    private func contrast(_ text: Shade, on background: Shade) -> Double {
        let foreground = composite(text, over: background)
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func assertHex(_ shade: Shade, _ hex: UInt32, sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = Shade(hex: hex)
        #expect(abs(shade.red - expected.red) < 0.003 && abs(shade.green - expected.green) < 0.003 && abs(shade.blue - expected.blue) < 0.003,
                "expected #\(String(hex, radix: 16, uppercase: true)), got \(shade)", sourceLocation: sourceLocation)
    }

    // Backgrounds the text is drawn on.
    private func popover(_ look: Look) -> Shade { Shade(hex: look.isDark ? 0x2B2B2B : 0xECECEC) }
    private func settingsWindow(_ look: Look) -> Shade { Shade(hex: look.isDark ? 0x1E1E1E : 0xFFFFFF) }
    private func settingsRow(_ look: Look) -> Shade {
        composite(resolved(Theme.fillGrouped, look), over: settingsWindow(look))
    }
    private func surface(_ look: Look) -> Shade { resolved(Theme.surfaceWindow, look) }

    // MARK: Values

    @Test func boostTextIsDarkAmberInLightAndPaleInDark() {
        assertHex(resolved(Theme.boostText, .light), 0x8A4F00)
        assertHex(resolved(Theme.boostText, .dark), 0xFFB84D)
    }

    @Test func boostAmberFillsKeepTheirValues() {
        assertHex(resolved(Theme.boost, .light), 0xF08C00)
        assertHex(resolved(Theme.boost, .dark), 0xFF9F0A)
        assertHex(resolved(Theme.boostHighlight, .light), 0xFFAE1F)
        assertHex(resolved(Theme.boostHighlight, .dark), 0xFFB84D)
        assertHex(resolved(Theme.sunGlyph, .light), 0xE8890C)
        assertHex(resolved(Theme.sunGlyph, .dark), 0xFFCE7A)
        assertHex(resolved(Theme.sunText, .light), 0x8F5200)
    }

    /// The HUD's lit Boost colour must tell lit from unlit Boost segments, and
    /// read as a glyph, at 3:1 in every look. The HUD sits on a material that
    /// measures about #EBEBEB in light and #303030 in dark.
    @Test(arguments: Look.allCases)
    private func hudBoostIsLegible(look: Look) {
        let background = Shade(hex: look.isDark ? 0x303030 : 0xEBEBEB)
        let lit = resolved(Theme.hudBoost, look)
        let unlit = composite(resolved(Theme.boostStripe, look), over: background)
        #expect(contrast(lit, on: unlit) >= 3, "lit vs unlit Boost, \(look)")
        #expect(contrast(lit, on: background) >= 3, "lit Boost vs HUD, \(look)")
    }

    @Test func hudBoostValues() {
        assertHex(resolved(Theme.hudBoost, .light), 0x9A5800)
        assertHex(resolved(Theme.hudBoost, .dark), 0xFF9F0A)
    }

    /// The inactive page dot is the only sign of which step is current, so it
    /// needs 3:1 against the onboarding background, and the active dot must
    /// stand clearly apart from it.
    @Test(arguments: Look.allCases)
    private func pageDotsAreLegible(look: Look) {
        let background = surface(look)
        let inactive = composite(resolved(Theme.pageDotInactive, look), over: background)
        let active = composite(resolved(Theme.pageDotActive, look), over: background)
        #expect(contrast(inactive, on: background) >= 3, "inactive dot, \(look)")
        #expect(contrast(active, on: inactive) >= 1.5, "active vs inactive dot, \(look)")
    }

    @Test func statusAndAccentValues() {
        assertHex(resolved(Theme.accentButton, .light), 0x0071E3)
        assertHex(resolved(Theme.accentButton, .dark), 0x0071E3)
        assertHex(resolved(Theme.recorderError, .light), 0xC4001A)
        assertHex(resolved(Theme.recorderError, .dark), 0xFF9C96)
    }

    @Test func textAlphasMatchTheMeasuredValues() {
        #expect(resolved(Theme.textSecondary, .light).alpha == 0.65)
        #expect(resolved(Theme.textSecondary, .dark).alpha == 0.65)
        #expect(resolved(Theme.textTertiary, .dark).alpha == 0.58)
        #expect(resolved(Theme.textTertiary, .light).alpha == 0.6)
        #expect(resolved(Theme.fillTrack, .light).alpha == 0.11)
        #expect(resolved(Theme.fillTrack, .dark).alpha == 0.16)
        #expect(resolved(Theme.fillGrouped, .light).alpha == 0.06)
        #expect(resolved(Theme.fillGrouped, .dark).alpha == 0.09)
    }

    @Test func increaseContrastDarkensTextAndStrengthensFills() {
        for (normal, increased) in [(Look.light, Look.lightIncreased), (.dark, .darkIncreased)] {
            #expect(resolved(Theme.textSecondary, increased).alpha == 0.8)
            #expect(resolved(Theme.textTertiary, increased).alpha == 0.72)
            #expect(resolved(Theme.divider, increased).alpha == 0.3)
            #expect(resolved(Theme.fillTrack, increased).alpha >= 0.3)
            #expect(resolved(Theme.fillGrouped, increased).alpha > resolved(Theme.fillGrouped, normal).alpha)
            #expect(resolved(Theme.fillControl, increased).alpha > resolved(Theme.fillControl, normal).alpha)
        }
    }

    @Test func swiftUIColorsResolveThroughTheSameDynamicProvider() {
        for look in Look.allCases {
            var viaColor = Shade.black()
            look.appearance.performAsCurrentDrawingAppearance {
                let color = NSColor(Color.boostText).usingColorSpace(.sRGB)!
                viaColor = Shade(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
            }
            let direct = resolved(Theme.boostText, look)
            #expect(abs(viaColor.red - direct.red) < 0.003 && abs(viaColor.green - direct.green) < 0.003, "\(look)")
        }
    }

    @Test func dividersAreHairlinesUntilIncreaseContrast() {
        #expect(ThemeDivider.thickness(increased: false) == 0.5)
        #expect(ThemeDivider.thickness(increased: true) == 1)
    }

    // MARK: Contrast

    private let minimum = 4.5

    @Test(arguments: Look.allCases)
    private func popoverTextClearsAA(look: Look) {
        let background = popover(look)
        let pausedBadge = composite(resolved(Theme.fillGrouped, look), over: background)
        let boostTint = composite(resolved(Theme.boostFill, look), over: background)
        let checks: [(String, Shade, Shade)] = [
            ("primary", resolved(Theme.textPrimary, look), background),
            ("secondary", resolved(Theme.textSecondary, look), background),
            ("tertiary and shortcut", resolved(Theme.textTertiary, look), background),
            ("row text", resolved(Theme.textRow, look), background),
            ("paused badge", resolved(Theme.textSecondary, look), pausedBadge),
            ("quick-set label", resolved(Theme.textPrimary, look), pausedBadge),
            ("BOOSTED and Max boi", resolved(Theme.boostText, look), boostTint),
            ("amber banner text", resolved(Theme.textRow, look), boostTint),
            ("info banner text", resolved(Theme.textRow, look), pausedBadge)
        ]
        for (name, text, back) in checks {
            #expect(contrast(text, on: back) >= minimum, "\(name) \(look): \(contrast(text, on: back))")
        }
    }

    @Test(arguments: Look.allCases)
    private func settingsTextClearsAA(look: Look) {
        let window = settingsWindow(look)
        let row = settingsRow(look)
        let pill = composite(resolved(Theme.fillGrouped, look), over: row)
        let control = composite(resolved(Theme.fillControl, look), over: row)
        let checks: [(String, Shade, Shade)] = [
            ("section header", resolved(Theme.textTertiary, look), window),
            ("footer", resolved(Theme.textTertiary, look), window),
            ("row title", resolved(Theme.textRow, look), row),
            ("subtitle", resolved(Theme.textSecondary, look), row),
            ("range labels", resolved(Theme.textTertiary, look), row),
            ("recorder error", resolved(Theme.recorderError, look), pill),
            ("shortcut", resolved(Theme.textRow, look), pill),
            ("reset link", resolved(Theme.accentText, look), row),
            ("action button", resolved(Theme.textRow, look), control),
            ("notice", resolved(Theme.textSecondary, look), window)
        ]
        for (name, text, back) in checks {
            #expect(contrast(text, on: back) >= minimum, "\(name) \(look): \(contrast(text, on: back))")
        }
    }

    @Test(arguments: Look.allCases)
    private func onboardingAndDonationTextClearsAA(look: Look) {
        let background = surface(look)
        let row = composite(resolved(Theme.fillGrouped, look), over: background)
        let skip = composite(resolved(Theme.fillControl, look), over: background)
        let checks: [(String, Shade, Shade)] = [
            ("title", resolved(Theme.textPrimary, look), background),
            ("body", resolved(Theme.textSecondary, look), background),
            ("caption", resolved(Theme.textTertiary, look), background),
            ("row subtitle", resolved(Theme.textTertiary, look), row),
            ("Done", resolved(Theme.textSecondary, look), row),
            ("Everything it didn't", resolved(Theme.sunText, look), row),
            ("skip label", resolved(Theme.textSecondary, look), skip),
            ("white on accent", .white(), resolved(Theme.accentButton, look))
        ]
        for (name, text, back) in checks {
            #expect(contrast(text, on: back) >= minimum, "\(name) \(look): \(contrast(text, on: back))")
        }
    }

    @Test func donationCTATextClearsAAOnBrandYellow() {
        #expect(contrast(Shade(red: 0.051, green: 0.047, blue: 0.043), on: Shade(red: 1, green: 0.867, blue: 0)) >= minimum)
    }
}
