import AppKit
import ServiceManagement
import SwiftUI

/// BrightBoi's Settings window: Boost Ceiling, Key Remap
/// shortcut + on/off toggle, and a Permissions panel. Colours, type and radii
/// come from `Theme`.
struct SettingsView: View {
    var controller: BrightnessController
    var permissions: PermissionsModel

    @State private var recorder: ShortcutRecorder

    init(controller: BrightnessController, permissions: PermissionsModel, recorder: ShortcutRecorder? = nil) {
        self.controller = controller
        self.permissions = permissions
        _recorder = State(initialValue: recorder ?? ShortcutRecorder(controller: controller))
    }

    var body: some View {
        let state = controller.currentState
        // Shortcut labels follow the keyboard layout, so redraw when it changes.
        let _ = KeyboardLayoutNames.shared.generation

        VStack(alignment: .leading, spacing: 18) {
            generalSection(state: state)

            if state.supportsBoost {
                boostCeilingSection(state: state)
            }

            permissionsSection(state: state)

            footer()
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 18, trailing: 22))
        .frame(width: 480)
        .onDisappear { recorder.teardown() }
        .onAppear {
            controller.refreshLaunchAtLoginStatus()
            controller.syncFromDisplay()
            controller.permissionsMayHaveChanged()
        }
        // SwiftUI doesn't reliably re-run `onAppear` when Settings is
        // reopened, and System Settings' Login Items list can change
        // BrightBoi's registration (approval, removal) without BrightBoi
        // hearing about it directly — so also refresh whenever the app
        // becomes active, whichever way that happens.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshLaunchAtLoginStatus()
            controller.syncFromDisplay()
            controller.permissionsMayHaveChanged()
        }
    }

    // MARK: - General

    private func generalSection(state: BrightnessController.State) -> some View {
        section(title: "General") {
            VStack(alignment: .leading, spacing: 6) {
                VStack(spacing: 0) {
                    toggleRow(
                        title: "Launch at login",
                        isOn: Binding(
                            get: { state.launchAtLoginEnabled },
                            set: { controller.setLaunchAtLoginEnabled($0) }
                        )
                    )

                    rowDivider()

                    toggleRow(
                        title: "Turn off macOS auto-brightness while BrightBoi runs",
                        subtitle: "Otherwise the light sensor can undo the level you set. Your original setting is always restored on quit.",
                        isOn: Binding(
                            get: { state.autoBrightnessTakeoverEnabled },
                            set: { controller.setAutoBrightnessTakeoverEnabled($0) }
                        )
                    )

                    rowDivider()

                    toggleRow(
                        title: remapToggleTitle(state.keyRemapShortcut),
                        subtitle: "The brightness keys step in 5% jumps across the whole 0–200% range instead of stopping at 100%.",
                        isOn: Binding(
                            get: { state.keyRemapEnabled },
                            set: { controller.setKeyRemapEnabled($0) }
                        )
                    )

                    rowDivider()

                    shortcutRow(press: .raise, combo: state.keyRemapShortcut.raise)

                    rowDivider()

                    shortcutRow(press: .lower, combo: state.keyRemapShortcut.lower)

                    if state.keyRemapShortcut != .defaultShortcut {
                        rowDivider()
                        resetShortcutRow()
                    }
                }
                .background(Color.settingsGroupFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .contrastBorder(cornerRadius: Theme.Radius.card)

                launchAtLoginNotice(state: state)
                autoBrightnessUnavailableNotice()
                keyRemapNotice(state: state)
            }
        }
    }

    /// Shown only when the private CoreBrightness symbol couldn't be
    /// loaded — the toggle above still exists, but flipping it can't
    /// actually change anything, so this says so rather than staying
    /// silently ineffective.
    @ViewBuilder
    private func autoBrightnessUnavailableNotice() -> some View {
        if controller.autoBrightnessUnavailable {
            Text("Couldn't reach macOS's auto-brightness setting on this system — this switch has no effect.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textSecondary)
        }
    }

    /// Explains why the switch above doesn't match what the user might
    /// expect: approval pending in System Settings, or registration withheld
    /// because BrightBoi isn't running from a proper Applications location.
    /// A thrown registration/unregistration error takes the same slot.
    @ViewBuilder
    private func launchAtLoginNotice(state: BrightnessController.State) -> some View {
        if state.launchAtLoginNeedsApproval {
            HStack {
                Text("Needs approval in System Settings → Login Items.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Button("Open Login Items") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.link(foreground: .textRow, horizontalPadding: 6, verticalPadding: 3))
                .font(Theme.Typography.secondaryMedium)
                .padding(.trailing, -6)
            }
        } else if let message = state.launchAtLoginStatusMessage {
            Text(message)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textSecondary)
        }
    }

    /// Says so when Key Remap is on but not working, with the way to fix it,
    /// so a dead tap is never silent; or names another app that takes the
    /// brightness keys first.
    @ViewBuilder
    private func keyRemapNotice(state: BrightnessController.State) -> some View {
        if state.keyRemapEnabled && !controller.keyRemapActive {
            AdvisoryBanner(
                icon: "exclamationmark.triangle.fill",
                text: "Key Remap isn't active, so macOS still handles the brightness keys."
            ) {
                if !permissions.accessibilityGranted {
                    actionButton("Turn on…") { permissions.requestOrOpenSettings(.accessibility) }
                } else if permissions.inputMonitoringGranted {
                    actionButton("Relaunch BrightBoi") { AppRelauncher.relaunch() }
                } else {
                    actionButton("Try again") { controller.permissionsMayHaveChanged() }
                }
            }
        } else if state.keyRemapEnabled, let conflict = controller.keyTapConflict {
            AdvisoryBanner(icon: "exclamationmark.triangle.fill", text: conflict.message)
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(PillButtonStyle())
            .font(Theme.Typography.control)
    }

    private func remapToggleTitle(_ shortcut: KeyRemapShortcut) -> String {
        shortcut == .defaultShortcut
            ? "Let BrightBoi own F1 / F2"
            : "Let BrightBoi own \(shortcut.lower.displayString) / \(shortcut.raise.displayString)"
    }

    // MARK: - Boost Ceiling

    private func boostCeilingSection(state: BrightnessController.State) -> some View {
        section(title: "Boost ceiling") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .lastTextBaseline) {
                    Text("Don't let me go past")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Color.textRow)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("\(Int(state.boostCeiling))%")
                            .font(Theme.Typography.value)
                            .foregroundStyle(Color.textPrimary)
                        Text("· \(Int(state.boostCeilingNits)) nits")
                            .font(Theme.Typography.secondary.monospacedDigit())
                            .foregroundStyle(Color.textSecondary)
                    }
                }

                Slider(
                    value: Binding(
                        get: { state.boostCeiling },
                        set: { controller.setBoostCeiling($0) }
                    ),
                    in: BrightnessController.nominalCeilingPercentage...BrightnessController.maximumPercentage,
                    step: BrightnessController.percentageGranularity
                )
                .tint(.boost)

                HStack {
                    Text("100%")
                    Spacer()
                    Text("200% · 1000 nits")
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Color.textTertiary)

                Text("200% is the panel's sustained full-screen rating. BrightBoi won't offer more than that, no matter how nicely you ask.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(13)
            .background(Color.settingsGroupFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .contrastBorder(cornerRadius: Theme.Radius.card)
        }
    }

    // MARK: - Permissions

    private func permissionsSection(state: BrightnessController.State) -> some View {
        section(title: "Permissions") {
            VStack(alignment: .leading, spacing: 4) {
                VStack(spacing: 0) {
                    permissionRow(title: "Accessibility", granted: permissions.accessibilityGranted) {
                        permissions.requestOrOpenSettings(.accessibility)
                    }
                    // Whether this Mac needs Input Monitoring for the key tap
                    // is only known when the tap fails with Accessibility
                    // already granted, so the row appears only then.
                    if permissions.needsInputMonitoring(keyRemapEnabled: state.keyRemapEnabled, keyTapActive: controller.keyRemapActive) {
                        rowDivider()
                        permissionRow(title: "Input Monitoring", granted: permissions.inputMonitoringGranted) {
                            permissions.requestOrOpenSettings(.inputMonitoring)
                        }
                    }
                }
                .background(Color.settingsGroupFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .contrastBorder(cornerRadius: Theme.Radius.card)
                .animation(.default, value: permissions.accessibilityGranted)

                Text("Needed only for the brightness keys. The slider and custom shortcuts work without it.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private func permissionRow(title: String, granted: Bool, onGrant: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(Color.textRow)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? Color.green : Color.boost)
                Text(granted ? "Granted" : "Not granted")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Color.textSecondary)
            }
            if !granted {
                actionButton("Turn on…", action: onGrant)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private func footer() -> some View {
        HStack {
            Text("BrightBoi 1.0 · built-in display only")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textTertiary)
            Spacer()
            Button("Quit BrightBoi") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(PillButtonStyle(horizontalPadding: 12, verticalPadding: 5))
            .font(Theme.Typography.control)
        }
    }

    // MARK: - Shared row building blocks

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.Typography.sectionHeader)
                .tracking(0.3)
                .foregroundStyle(Color.settingsSectionHeader)
            content()
        }
    }

    private func toggleRow(title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Color.textRow)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    private func shortcutRow(press: BrightnessController.KeyPress, combo: KeyCombo) -> some View {
        HStack {
            Text(press.label)
                .font(Theme.Typography.body)
                .foregroundStyle(Color.textRow)
            Spacer()
            ShortcutPill(press: press, combo: combo, recorder: recorder)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    /// Shown only while the shortcut differs from the default, so there is
    /// always a way back to F1 / F2.
    private func resetShortcutRow() -> some View {
        HStack {
            Spacer()
            Button("Reset to F1 / F2") {
                controller.resetKeyRemapShortcut()
            }
            .buttonStyle(.link(foreground: .accentText, horizontalPadding: 6, verticalPadding: 3))
            .font(Theme.Typography.secondaryMedium)
            .accessibilityHint("Restores F1 for Lower and F2 for Raise")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 9)
    }

    private func rowDivider() -> some View {
        ThemeDivider()
            .padding(.leading, 13)
    }
}
