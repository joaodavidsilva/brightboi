import SwiftUI

/// The three-step first-run window: welcome, the permission request,
/// confirmation. Hosted in `OnboardingWindowController`'s `NSWindow` — this
/// view only renders whatever `OnboardingModel.step` currently is and
/// forwards button taps to the model, which owns all the flow and
/// persistence logic.
///
/// `supportsBoost` and `keyRemapActive` are plain values, read live by the
/// host from the controller, because the welcome and confirmation words
/// depend on what this Mac and this launch can really do.
struct OnboardingView: View {
    var model: OnboardingModel
    var supportsBoost = true
    var keyRemapActive = true

    static let contentSize = CGSize(width: 380, height: 420)

    /// Where the headers of the permission and confirmation steps start,
    /// measured from the top of the window. The welcome hero is centred.
    private static let headerTop: CGFloat = 52
    /// The room the Skip row always takes, so the main button stays at the
    /// same height on every step.
    private static let skipRowHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(nil, value: model.step)

            VStack(spacing: 6) {
                PrimaryButton(title: primaryTitle, action: model.advance)
                skipRow
                    .frame(height: Self.skipRowHeight)
            }
            .padding(.horizontal, 28)

            pageDots()
                .padding(.top, 14)
                .padding(.bottom, 18)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(Color.surfaceWindow)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .welcome:
            WelcomeStepView(supportsBoost: supportsBoost)
        case .permissions:
            PermissionsStepView(model: model)
                .padding(.top, Self.headerTop)
                .frame(maxHeight: .infinity, alignment: .top)
        case .confirmation:
            ConfirmationStepView(copy: OnboardingCopy.confirmation(supportsBoost: supportsBoost, keyRemapActive: keyRemapActive))
                .padding(.top, Self.headerTop)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: "Let's go"
        case .permissions: OnboardingCopy.permissionsContinueTitle(accessibilityGranted: model.accessibilityGranted)
        case .confirmation: "Get bright"
        }
    }

    /// The permission step's way past without granting, also bound to Esc.
    /// Nothing is shown once Accessibility is granted, or on other steps.
    @ViewBuilder
    private var skipRow: some View {
        if model.step == .permissions && !model.accessibilityGranted {
            Button("Skip — slider only", action: model.skip)
                .buttonStyle(PillButtonStyle(
                    foreground: .textSecondary,
                    cornerRadius: Theme.Radius.button,
                    horizontalPadding: 0,
                    verticalPadding: 8,
                    fillsWidth: true
                ))
                .font(Theme.Typography.buttonLarge)
                .keyboardShortcut(.cancelAction)
        } else {
            Color.clear
        }
    }

    private func pageDots() -> some View {
        let steps = OnboardingModel.Step.allCases
        let number = (steps.firstIndex(of: model.step) ?? 0) + 1
        return HStack(spacing: 5) {
            ForEach(steps, id: \.self) { step in
                Circle()
                    .fill(step == model.step ? Color.pageDotActive : Color.pageDotInactive)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number) of \(steps.count)")
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    var supportsBoost: Bool

    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: Theme.GlyphSize.onboarding))
                .foregroundStyle(Color.sunGlyph)
                .accessibilityHidden(true)

            Text("Hey, I'm BrightBoi.")
                .font(Theme.Typography.title)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)

            Text(OnboardingCopy.welcomeBody(supportsBoost: supportsBoost))
                .font(Theme.Typography.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Text("I also switch off macOS's auto-brightness so the light sensor can't undo your level — I put it back the way I found it when you quit.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(.horizontal, 30)
        .onAppear { titleFocused = true }
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStepView: View {
    var model: OnboardingModel

    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One permission, then I'll be quiet.")
                .font(Theme.Typography.title)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)

            Text(OnboardingCopy.permissionsIntro(accessibilityGranted: model.accessibilityGranted))
                .font(Theme.Typography.body)
                .foregroundStyle(Color.textSecondary)

            VStack(spacing: 0) {
                permissionRow(
                    title: "Accessibility",
                    subtitle: OnboardingCopy.permissionSubtitle,
                    granted: model.accessibilityGranted,
                    onGrant: model.requestAccessibility
                )
            }
            .background(Color.fillGrouped, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .contrastBorder(cornerRadius: Theme.Radius.card)
            .animation(.default, value: model.accessibilityGranted)
        }
        .padding(.horizontal, 28)
        .onAppear { titleFocused = true }
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
            // Name, purpose, then status, as one line for VoiceOver.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OnboardingCopy.permissionRowLabel(title: title, subtitle: subtitle, granted: granted))
            .accessibilityAddTraits(.isStaticText)
            Spacer()
            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Done")
                        .foregroundStyle(Color.textSecondary)
                }
                .font(Theme.Typography.callout)
                .accessibilityHidden(true)
            } else {
                Button("Grant", action: onGrant)
                    .buttonStyle(PillButtonStyle(
                        fill: .accentButton,
                        foreground: .white,
                        horizontalPadding: 12,
                        verticalPadding: 5
                    ))
                    .font(Theme.Typography.control)
                    .accessibilityLabel("Grant \(title)")
                    .accessibilityInputLabels(["Grant", "Grant \(title)"])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

// MARK: - Step 3: Confirmation

private struct ConfirmationStepView: View {
    var copy: OnboardingCopy.Confirmation

    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're up top now.")
                .font(Theme.Typography.title)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)

            Text(copy.body)
                .font(Theme.Typography.body)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Can't see the sun? Your menu bar may be full. Open BrightBoi again from Applications.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if copy.showsIllustration {
                BoostRangeIllustration()
            }
        }
        .padding(.horizontal, 28)
        .onAppear { titleFocused = true }
    }
}

/// The range in one picture: the Nominal half drawn as the popover's slider
/// draws it, a hairline cut, and the Boost half in the popover's striped
/// amber, with a caption under each half.
private struct BoostRangeIllustration: View {
    private static let trackHeight: CGFloat = 6
    private static let cut: CGFloat = 1.5

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let half = max(0, proxy.size.width / 2 - Self.cut / 2)
                HStack(spacing: Self.cut) {
                    Rectangle()
                        .fill(Color.sliderNominal)
                        .frame(width: half)
                    ZStack {
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [Color.boostHighlight, Color.boost],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .opacity(0.45)
                        DiagonalStripes()
                            .stroke(Color.boostStripe, lineWidth: 2.5)
                    }
                    .frame(width: half)
                    .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.trackHeight / 2))
            }
            .frame(height: Self.trackHeight)
            .accessibilityHidden(true)

            HStack(spacing: 0) {
                Text("Everything macOS gave you")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Everything it didn't")
                    .foregroundStyle(Color.sunText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(Theme.Typography.secondary)
            .foregroundStyle(Color.textTertiary)
        }
        .padding(13)
        .background(Color.fillGrouped, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .contrastBorder(cornerRadius: Theme.Radius.card)
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
        // hands initial keyboard focus to by default: without it, Return
        // activated the window's own close button instead of this one.
        .keyboardShortcut(.defaultAction)
    }
}
