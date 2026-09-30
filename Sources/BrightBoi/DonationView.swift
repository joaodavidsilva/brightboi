import AppKit
import SwiftUI

/// The "Buy me a coffee" window: single CTA, "Not today"/Esc dismiss. No
/// 1/3/5-coffee preset buttons — Buy Me a Coffee has no URL parameter to
/// pre-fill an amount and the account has no fixed minimum. Hosted in
/// `DonationWindowController`'s `NSWindow`, which never takes keyboard focus
/// on its own; this view only renders content, and calls back into
/// `onDismiss` for the "Not today" tap, for Esc, and once the support page
/// has opened. It shows the Esc hint only once `keyState` says Esc would
/// actually reach the window.
struct DonationView: View {
    var keyState: DonationWindowKeyState
    var onDismiss: () -> Void
    /// Opens the support page and reports whether it opened. Injectable so
    /// nothing that renders or clicks this view in a test can reach the
    /// browser.
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }

    static let contentWidth: CGFloat = 380

    /// Buy Me a Coffee's brand yellow and the dark text on it. They are the
    /// brand's own colours, so they are the same in both appearances and stay
    /// outside `Theme`.
    private static let ctaBackground = Color(red: 1.0, green: 0.867, blue: 0.0)
    private static let ctaText = Color(red: 0.051, green: 0.047, blue: 0.043)

    private static let supportURL = URL(string: "https://buymeacoffee.com/ptlghost")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: Theme.GlyphSize.donation))
                    .foregroundStyle(Color.sunGlyph)
                    .accessibilityHidden(true)
                Text("Free app. Expensive boi.")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }

            Text("BrightBoi is free and stays free. If it's earned its spot in your menu bar, you can buy the developer a coffee — entirely up to you.")
                .font(Theme.Typography.body)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Button(action: openSupportPage) {
                    Text("Buy me a coffee")
                        .font(Theme.Typography.brandCTA)
                }
                .buttonStyle(PillButtonStyle(
                    fill: Self.ctaBackground,
                    foreground: Self.ctaText,
                    cornerRadius: Theme.Radius.button,
                    horizontalPadding: 0,
                    verticalPadding: 9,
                    fillsWidth: true
                ))

                HStack(spacing: 8) {
                    Button("Not today", action: onDismiss)
                        .buttonStyle(.link(foreground: .textSecondary, horizontalPadding: 8, verticalPadding: 6))
                        .font(Theme.Typography.buttonLarge)
                        .keyboardShortcut(.cancelAction)

                    if keyState.isKey {
                        Text("or press Esc")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 2)

            ThemeDivider()

            Text("Opens buymeacoffee.com in your browser.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 20)
        .frame(width: Self.contentWidth)
        .background(Color.surfaceWindow)
    }

    /// Closes the window once the page has opened, so it is not left over
    /// behind the browser. A failed open leaves it up to try again.
    private func openSupportPage() {
        if openURL(Self.supportURL) { onDismiss() }
    }
}
