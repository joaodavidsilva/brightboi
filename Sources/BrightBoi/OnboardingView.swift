import SwiftUI

/// The three-step first-run window (mockups 1e/2e): welcome, permission
/// requests with a skip escape hatch, confirmation. Hosted in
/// `OnboardingWindowController`'s `NSWindow` — this view only renders
/// whatever `OnboardingModel.step` currently is and forwards button taps to
/// the model, which owns all the flow/persistence logic.
struct OnboardingView: View {
    var model: OnboardingModel

    @Environment(\.colorScheme) private var colorScheme

    static let contentSize = CGSize(width: 380, height: 420)

    var body: some View {
        let palette = Palette(colorScheme: colorScheme)

        VStack(spacing: 0) {
            Spacer(minLength: 0)

            switch model.step {
            case .welcome:
                WelcomeStepView(palette: palette, onAdvance: model.advance)
            case .permissions:
                PermissionsStepView(model: model, palette: palette)
            case .confirmation:
                ConfirmationStepView(palette: palette, onAdvance: model.advance)
            }

            Spacer(minLength: 0)

            pageDots(palette: palette)
                .padding(.bottom, 22)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(palette.background)
    }

    private func pageDots(palette: Palette) -> some View {
        HStack(spacing: 5) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == model.step ? palette.dotActive : palette.dotInactive)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    var palette: OnboardingView.Palette
    var onAdvance: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 40))
                .foregroundStyle(palette.sunGlyph)

            Text("Hey, I'm BrightBoi.")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.primaryText)

            Text("Your screen has been holding out on you. macOS stops the slider at 500 nits; the panel is rated for 1000. I go all the way there.")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            PrimaryButton(title: "Let's go", palette: palette, action: onAdvance)
                .padding(.top, 8)
        }
        .padding(.horizontal, 30)
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStepView: View {
    var model: OnboardingModel
    var palette: OnboardingView.Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Two permissions, then I'll be quiet.")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.primaryText)

            Text("These are only for the F1/F2 keys. macOS will ask you twice — that's the system, not me.")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryText)

            VStack(spacing: 0) {
                permissionRow(
                    title: "Accessibility",
                    subtitle: "So the keypress can be intercepted",
                    granted: model.accessibilityGranted,
                    onGrant: model.requestAccessibility
                )
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 0.5)
                    .padding(.leading, 12)
                permissionRow(
                    title: "Input Monitoring",
                    subtitle: "So the media-key form is seen too",
                    granted: model.inputMonitoringGranted,
                    onGrant: model.requestInputMonitoring
                )
            }
            .background(palette.rowBackground, in: RoundedRectangle(cornerRadius: 9))

            PrimaryButton(title: "Continue", palette: palette, action: model.advance)

            Button("Skip — slider only", action: model.skip)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(palette.skipBackground, in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 28)
    }

    private func permissionRow(title: String, subtitle: String, granted: Bool, onGrant: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.primaryText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiaryText)
            }
            Spacer()
            if granted {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                Button("Grant", action: onGrant)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

// MARK: - Step 3: Confirmation

private struct ConfirmationStepView: View {
    var palette: OnboardingView.Palette
    var onAdvance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're up top now.")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(palette.primaryText)

            Text("I live in the menu bar. Click the sun, or just hit F2 past where it used to stop.")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryText)

            VStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(palette.trackBackground)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(palette.primaryText)
                        .frame(width: 100, height: 6)
                }
                HStack {
                    Text("Everything macOS gave you")
                    Spacer()
                    Text("Everything it didn't")
                        .foregroundStyle(palette.sunGlyph)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(palette.tertiaryText)
            }
            .padding(13)
            .background(palette.rowBackground, in: RoundedRectangle(cornerRadius: 9))

            PrimaryButton(title: "Get bright", palette: palette, action: onAdvance)
        }
        .padding(.horizontal, 28)
    }
}

// MARK: - Shared building blocks

private struct PrimaryButton: View {
    var title: String
    var palette: OnboardingView.Palette
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(palette.accent, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

extension OnboardingView {
    /// Every color this window draws, resolved once per render from
    /// `colorScheme` — same pattern as `BrightnessMenuContent.Palette`.
    struct Palette {
        let background: Color
        let primaryText: Color
        let secondaryText: Color
        let tertiaryText: Color
        let accent: Color
        let sunGlyph: Color
        let rowBackground: Color
        let skipBackground: Color
        let divider: Color
        let trackBackground: Color
        let dotActive: Color
        let dotInactive: Color

        init(colorScheme: ColorScheme) {
            switch colorScheme {
            case .dark:
                background = Color(red: 0.122, green: 0.122, blue: 0.135)
                primaryText = .white
                secondaryText = Color.white.opacity(0.6)
                tertiaryText = Color.white.opacity(0.42)
                accent = Color(red: 0.039, green: 0.518, blue: 1.0)
                sunGlyph = Color(red: 1.0, green: 0.808, blue: 0.478)
                rowBackground = Color.white.opacity(0.06)
                skipBackground = Color.white.opacity(0.1)
                divider = Color.white.opacity(0.09)
                trackBackground = Color.white.opacity(0.16)
                dotActive = Color.white.opacity(0.85)
                dotInactive = Color.white.opacity(0.22)
            case .light:
                fallthrough
            @unknown default:
                background = Color(red: 0.949, green: 0.949, blue: 0.957)
                primaryText = Color(red: 0.114, green: 0.114, blue: 0.122)
                secondaryText = Color.black.opacity(0.55)
                tertiaryText = Color.black.opacity(0.42)
                accent = Color(red: 0.0, green: 0.478, blue: 1.0)
                sunGlyph = Color(red: 0.910, green: 0.537, blue: 0.047)
                rowBackground = Color.white
                skipBackground = Color.white
                divider = Color.black.opacity(0.08)
                trackBackground = Color.black.opacity(0.11)
                dotActive = Color.black.opacity(0.6)
                dotInactive = Color.black.opacity(0.16)
            }
        }
    }
}
