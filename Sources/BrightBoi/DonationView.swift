import AppKit
import SwiftUI

/// The "Buy me a coffee" window (mockup 3a/3b): single CTA, "Not today"/Esc
/// dismiss. No 1/3/5-coffee preset buttons — dropped per ticket 06, since
/// Buy Me a Coffee has no URL parameter to pre-fill an amount and the
/// account has no fixed minimum. Hosted in `DonationWindowController`'s
/// `NSWindow`; this view only renders content and calls back into
/// `onDismiss` for both the "Not today" tap and Esc.
struct DonationView: View {
    var onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    static let contentSize = CGSize(width: 380, height: 300)

    private static let supportURL = URL(string: "https://buymeacoffee.com/ptlghost")!

    var body: some View {
        let palette = Palette(colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(palette.sunGlyph)
                Text("Free app. Expensive boi.")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
            }

            Text("You're pulling 1000 nits out of hardware you already own. If that made an afternoon outside bearable, buy me a coffee — entirely up to you. BrightBoi already started; it's up in the menu bar.")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Button(action: openSupportPage) {
                    Text("Buy me a coffee")
                        .font(.system(size: 13.5, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(palette.ctaText)
                        .background(palette.ctaBackground, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                HStack(spacing: 8) {
                    Button("Not today", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .keyboardShortcut(.cancelAction)

                    Text("or just press ⎋")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryText)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 2)

            Rectangle()
                .fill(palette.divider)
                .frame(height: 0.5)

            Text("Opens buymeacoffee.com in your browser.")
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryText)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(width: Self.contentSize.width)
        .background(palette.background)
    }

    private func openSupportPage() {
        NSWorkspace.shared.open(Self.supportURL)
    }
}

extension DonationView {
    /// Every color this window draws, resolved once per render from
    /// `colorScheme` — same pattern as `OnboardingView.Palette`. The sun
    /// glyph and background values match `OnboardingView.Palette` exactly
    /// (the mockup's hex values for both windows coincide), kept as
    /// separate constants here since this window's palette is otherwise
    /// independent.
    struct Palette {
        let background: Color
        let primaryText: Color
        let secondaryText: Color
        let tertiaryText: Color
        let sunGlyph: Color
        let ctaBackground: Color
        let ctaText: Color
        let divider: Color

        init(colorScheme: ColorScheme) {
            // Buy Me a Coffee's brand yellow — identical in both mockup
            // variants, so it isn't scheme-dependent.
            ctaBackground = Color(red: 1.0, green: 0.867, blue: 0.0)
            ctaText = Color(red: 0.051, green: 0.047, blue: 0.043)

            switch colorScheme {
            case .dark:
                background = Color(red: 0.122, green: 0.122, blue: 0.135)
                primaryText = .white
                secondaryText = Color.white.opacity(0.6)
                tertiaryText = Color.white.opacity(0.45)
                sunGlyph = Color(red: 1.0, green: 0.808, blue: 0.478)
                divider = Color.white.opacity(0.1)
            case .light:
                fallthrough
            @unknown default:
                background = Color(red: 0.949, green: 0.949, blue: 0.957)
                primaryText = Color(red: 0.114, green: 0.114, blue: 0.122)
                secondaryText = Color.black.opacity(0.55)
                tertiaryText = Color.black.opacity(0.45)
                sunGlyph = Color(red: 0.910, green: 0.537, blue: 0.047)
                divider = Color.black.opacity(0.1)
            }
        }
    }
}
