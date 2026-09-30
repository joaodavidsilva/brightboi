import SwiftUI

/// The three-step first-run window: welcome, the permission request with a
/// skip escape hatch, confirmation. Hosted in
/// `OnboardingWindowController`'s `NSWindow` — this view only renders
/// whatever `OnboardingModel.step` currently is and forwards button taps to
/// the model, which owns all the flow/persistence logic.
struct OnboardingView: View {
    var model: OnboardingModel

    static let contentSize = CGSize(width: 380, height: 420)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            switch model.step {
            case .welcome:
                WelcomeStepView(onAdvance: model.advance)
            case .permissions:
                PermissionsStepView(model: model)
            case .confirmation:
                ConfirmationStepView(onAdvance: model.advance)
            }

            Spacer(minLength: 0)

            pageDots()
                .padding(.bottom, 22)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(Color.surfaceWindow)
    }

    private func pageDots() -> some View {
        HStack(spacing: 5) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == model.step ? Color.pageDotActive : Color.pageDotInactive)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    var onAdvance: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: Theme.GlyphSize.onboarding))
                .foregroundStyle(Color.sunGlyph)

            Text("Hey, I'm BrightBoi.")
                .font(Theme.Typography.title)
                .foregroundStyle(Color.textPrimary)

            Text("Your screen has been holding out on you. macOS stops the slider at 500 nits; the panel is rated for 1000. I go all the way there.")
                .font(Theme.Typography.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Text("I also switch off macOS's auto-brightness so the light sensor can't undo your level — I put it back the way I found it when you quit.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            PrimaryButton(title: "Let's go", action: onAdvance)
                .padding(.top, 8)
        }
        .padding(.horizontal, 30)
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStepView: View {
    var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One permission, then I'll be quiet.")
                .font(Theme.Typography.title)
                .foregroundStyle(Color.textPrimary)

            Text("This is only for the F1/F2 keys. The slider works without it.")
                .font(Theme.Typography.body)
                .foregroundStyle(Color.textSecondary)

            VStack(spacing: 0) {
                permissionRow(
                    title: "Accessibility",
                    subtitle: "So BrightBoi can take over the brightness keys",
                    granted: model.accessibilityGranted,
                    onGrant: model.requestAccessibility
                )
            }
            .background(Color.fillGrouped, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .contrastBorder(cornerRadius: Theme.Radius.card)
            .animation(.default, value: model.accessibilityGranted)

            PrimaryButton(title: "Continue", action: model.advance)

            Button("Skip — slider only", action: model.skip)
                .buttonStyle(PillButtonStyle(
                    foreground: .textSecondary,
                    cornerRadius: Theme.Radius.button,
                    horizontalPadding: 0,
                    verticalPadding: 8,
                    fillsWidth: true
                ))
                .font(Theme.Typography.buttonLarge)
        }
        .padding(.horizontal, 28)
        // The grant happens in System Settings, where BrightBoi is not the
        // active app, so nothing notifies it: poll until the row flips.
        // SwiftUI cancels the task when the step changes or the window closes.
        .task {
            while !Task.isCancelled && !model.accessibilityGranted {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermissions()
            }
        }
    }

    private func permissionRow(title: String, subtitle: String, granted: Bool, onGrant: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer()
            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Done")
                        .foregroundStyle(Color.textSecondary)
                }
                .font(Theme.Typography.callout)
                .accessibilityElement(children: .combine)
            } else {
                Button("Grant", action: onGrant)
                    .buttonStyle(PillButtonStyle(
                        fill: .accentButton,
                        foreground: .white,
                        horizontalPadding: 12,
                        verticalPadding: 5
                    ))
                    .font(Theme.Typography.control)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

// MARK: - Step 3: Confirmation

private struct ConfirmationStepView: View {
    var onAdvance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're up top now.")
                .font(Theme.Typography.title)
                .foregroundStyle(Color.textPrimary)

            Text("I live in the menu bar. Click the sun, or just hit F2 past where it used to stop.")
                .font(Theme.Typography.body)
                .foregroundStyle(Color.textSecondary)

            VStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.fillTrack)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.textPrimary)
                        .frame(width: 100, height: 6)
                }
                HStack {
                    Text("Everything macOS gave you")
                    Spacer()
                    Text("Everything it didn't")
                        .foregroundStyle(Color.sunText)
                }
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textTertiary)
            }
            .padding(13)
            .background(Color.fillGrouped, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .contrastBorder(cornerRadius: Theme.Radius.card)

            PrimaryButton(title: "Get bright", action: onAdvance)
        }
        .padding(.horizontal, 28)
    }
}

// MARK: - Shared building blocks

private struct PrimaryButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.buttonLarge)
        }
        .buttonStyle(PillButtonStyle(
            fill: .accentButton,
            foreground: .white,
            cornerRadius: Theme.Radius.button,
            horizontalPadding: 0,
            verticalPadding: 8,
            fillsWidth: true
        ))
        // Explicit, rather than relying on whichever control the window
        // hands initial keyboard focus to by default — verified live that
        // without this, Return activated the window's own native close
        // button instead of this one, dismissing onboarding without
        // completing it.
        .keyboardShortcut(.defaultAction)
    }
}
