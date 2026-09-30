import AppKit
import ServiceManagement
import SwiftUI

/// BrightBoi's Settings window: a native grouped `Form` with General (launch
/// at login, auto-brightness takeover, Key Remap and its shortcuts), Boost
/// Ceiling and Permissions sections, then a footer with the version,
/// Support BrightBoi and Quit.
/// Rows use the system's own styles, so the window follows the platform's
/// look in both appearances.
struct SettingsView: View {
    var controller: BrightnessController
    var permissions: PermissionsModel
    /// Opens the donation window. It ignores the launch-time throttle.
    var onShowSupport: () -> Void = {}
    /// The update check. `nil` where there is none (previews and tests).
    var updates: UpdateChecker?

    @State private var recorder: ShortcutRecorder

    init(
        controller: BrightnessController,
        permissions: PermissionsModel,
        recorder: ShortcutRecorder? = nil,
        onShowSupport: @escaping () -> Void = {},
        updates: UpdateChecker? = nil
    ) {
        self.controller = controller
        self.permissions = permissions
        self.onShowSupport = onShowSupport
        self.updates = updates
        _recorder = State(initialValue: recorder ?? ShortcutRecorder(controller: controller))
    }

    var body: some View {
        let state = controller.currentState
        // Shortcut labels follow the keyboard layout, so redraw when it changes.
        let _ = KeyboardLayoutNames.shared.generation

        VStack(spacing: 0) {
            Form {
                generalSection(state: state)

                if state.supportsBoost {
                    boostCeilingSection(state: state)
                }

                permissionsSection(state: state)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)

            footer()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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
        Section {
            toggleRow(
                title: "Launch at login",
                isOn: Binding(
                    get: { state.launchAtLoginEnabled },
                    set: { controller.setLaunchAtLoginEnabled($0) }
                )
            )
            launchAtLoginNotice(state: state)

            toggleRow(
                title: "Turn off macOS auto-brightness while BrightBoi runs",
                subtitle: "Otherwise the light sensor can undo the level you set. Your original setting is always restored on quit.",
                isOn: Binding(
                    get: { state.autoBrightnessTakeoverEnabled },
                    set: { controller.setAutoBrightnessTakeoverEnabled($0) }
                )
            )
            autoBrightnessUnavailableNotice()

            toggleRow(
                title: Self.remapToggleTitle(state.keyRemapShortcut),
                subtitle: Self.remapSubtitle(
                    shortcut: state.keyRemapShortcut,
                    supportsBoost: state.supportsBoost,
                    boostCeiling: state.boostCeiling
                ),
                isOn: Binding(
                    get: { state.keyRemapEnabled },
                    set: { controller.setKeyRemapEnabled($0) }
                )
            )
            keyRemapNotice(state: state)

            shortcutRow(press: .lower, combo: state.keyRemapShortcut.lower)
            shortcutRow(press: .raise, combo: state.keyRemapShortcut.raise)

            if state.keyRemapShortcut != .defaultShortcut {
                resetShortcutRow()
            }

            if let updates {
                toggleRow(
                    title: "Check for updates automatically",
                    subtitle: "Contacts github.com once a day. Nothing is sent until you turn this on.",
                    isOn: Binding(
                        get: { updates.automaticChecksEnabled == true },
                        set: { updates.setAutomaticChecksEnabled($0) }
                    )
                )
            }
        } header: {
            sectionHeader("General")
        }
    }

    /// A section title that VoiceOver lists as a heading.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(title)
    }

    /// Shown only when the private CoreBrightness symbol couldn't be
    /// loaded: the toggle above still exists, but flipping it can't
    /// actually change anything, so this says so rather than staying
    /// silently ineffective.
    @ViewBuilder
    private func autoBrightnessUnavailableNotice() -> some View {
        if controller.autoBrightnessUnavailable {
            noticeRow(
                style: .attention,
                text: "Couldn't reach macOS's auto-brightness setting on this system — this switch has no effect."
            )
        }
    }

    /// Explains why the switch above doesn't match what the user might
    /// expect: approval pending in System Settings, or registration withheld
    /// because BrightBoi isn't running from a proper Applications location.
    /// A thrown registration/unregistration error takes the same slot.
    @ViewBuilder
    private func launchAtLoginNotice(state: BrightnessController.State) -> some View {
        if state.launchAtLoginNeedsApproval {
            noticeRow(style: .info, text: "Needs approval in System Settings → Login Items.") {
                Button("Open Login Items") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .controlSize(.small)
            }
        } else if let message = state.launchAtLoginStatusMessage {
            noticeRow(style: .attention, text: message)
        }
    }

    /// Says so when Key Remap is on but not working, with the way to fix it,
    /// so a dead tap is never silent; or names another app that takes the
    /// brightness keys first.
    @ViewBuilder
    private func keyRemapNotice(state: BrightnessController.State) -> some View {
        if state.keyRemapEnabled && !controller.keyRemapActive {
            noticeRow(
                style: .attention,
                text: "Key Remap isn't active, so macOS still handles the brightness keys."
            ) {
                if !permissions.accessibilityGranted {
                    Button("Turn on…") { permissions.requestOrOpenSettings(.accessibility) }
                        .controlSize(.small)
                } else if permissions.inputMonitoringGranted {
                    Button("Relaunch BrightBoi") { AppRelauncher.relaunch() }
                        .controlSize(.small)
                } else {
                    Button("Try again") { controller.permissionsMayHaveChanged() }
                        .controlSize(.small)
                }
            }
        } else if state.keyRemapEnabled, let conflict = controller.keyTapConflict {
            noticeRow(style: .attention, text: conflict.message)
        }
    }

    private enum NoticeStyle {
        /// Something is broken or needs the user's action.
        case attention
        /// Purely informational.
        case info
    }

    /// One explanatory line under a setting, with an optional button. An
    /// amber triangle marks what needs action; everything else is quiet.
    private func noticeRow(
        style: NoticeStyle,
        text: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: style == .attention ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(style == .attention ? Color.boost : Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action()
        }
    }

    nonisolated static func remapToggleTitle(_ shortcut: KeyRemapShortcut) -> String {
        "Let BrightBoi own \(shortcut.lower.displayString)/\(shortcut.raise.displayString)"
    }

    /// The Key Remap explanation, worded for what the keys will really do:
    /// the range follows the Boost Ceiling, and a Mac without Boost makes no
    /// claim about 200%. Word joiners around the en dash keep "0–150%" on one
    /// line.
    nonisolated static func remapSubtitle(
        shortcut: KeyRemapShortcut,
        supportsBoost: Bool,
        boostCeiling: Double
    ) -> String {
        let step = Int(BrightnessController.percentageGranularity)
        guard supportsBoost else { return "Each press moves brightness \(step)%." }
        let prefix = shortcut == .defaultShortcut ? "The brightness keys" : "These keys"
        let nominal = BrightnessController.nominalCeilingPercentage
        guard boostCeiling > nominal else { return "\(prefix) step \(step)% at a time." }
        return "\(prefix) step \(step)% at a time across 0\u{2060}–\u{2060}\(Int(boostCeiling))%, past the usual \(Int(nominal))% stop."
    }

    // MARK: - Boost Ceiling

    private func boostCeilingSection(state: BrightnessController.State) -> some View {
        Section {
            LabeledContent("Boost ceiling") {
                Text("\(Int(state.boostCeiling))% · \(Int(state.boostCeilingNits)) nits")
                    .monospacedDigit()
            }
            // The slider's own value carries the same numbers.
            .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { state.boostCeiling },
                    set: { controller.setBoostCeiling($0) }
                ),
                in: BrightnessController.nominalCeilingPercentage...BrightnessController.maximumPercentage
            ) {
                Text("Boost ceiling")
            } minimumValueLabel: {
                Text("100%").foregroundStyle(Color(nsColor: .secondaryLabelColor))
            } maximumValueLabel: {
                Text("200%").foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .labelsHidden()
            .tint(.boost)
            .accessibilityValue("\(Int(state.boostCeiling)) percent, \(Int(state.boostCeilingNits)) nits")
            .accessibilityHint("Highest brightness BrightBoi will let you set")
        } header: {
            sectionHeader("Boost Ceiling")
        } footer: {
            Text("BrightBoi won't set brightness above this. 200% is the panel's sustained full‑screen rating, the most BrightBoi offers.")
        }
    }

    // MARK: - Permissions

    private func needsInputMonitoring(_ state: BrightnessController.State) -> Bool {
        permissions.needsInputMonitoring(keyRemapEnabled: state.keyRemapEnabled, keyTapActive: controller.keyRemapActive)
    }

    private func permissionsSection(state: BrightnessController.State) -> some View {
        Section {
            permissionRow(title: "Accessibility", granted: permissions.accessibilityGranted) {
                permissions.requestOrOpenSettings(.accessibility)
            }
            // Whether this Mac needs Input Monitoring for the key tap
            // is only known when the tap fails with Accessibility
            // already granted, so the row appears only then.
            if needsInputMonitoring(state) {
                permissionRow(title: "Input Monitoring", granted: permissions.inputMonitoringGranted) {
                    permissions.requestOrOpenSettings(.inputMonitoring)
                }
            }
        } header: {
            sectionHeader("Permissions")
        } footer: {
            // "These", not "both": Input Monitoring is listed only on Macs
            // that need it.
            VStack(alignment: .leading, spacing: 6) {
                Text("Without these permissions the slider still works — F1/F2 go back to macOS's own brightness control, and a custom shortcut reaches whichever app is in front.")
                // After an update signed with a different certificate, macOS
                // can list BrightBoi as switched on while the old grant no
                // longer applies; removing and re-adding it is the fix.
                if !permissions.accessibilityGranted
                    || (needsInputMonitoring(state) && !permissions.inputMonitoringGranted) {
                    Text("Switched on in System Settings but still shown as Not granted? Select BrightBoi in that list, click the minus button and add it again.")
                }
            }
        }
    }

    /// What the status text says to VoiceOver: the permission's name and its
    /// state in one phrase, such as "Accessibility, Not granted".
    nonisolated static func permissionStatusLabel(title: String, granted: Bool) -> String {
        "\(title), \(granted ? "Granted" : "Not granted")"
    }

    /// Voice Control names for the button that starts a grant: what it says,
    /// and what it does.
    nonisolated static func turnOnInputLabels(for title: String) -> [String] {
        ["Turn on", "Turn on \(title)", "Open System Settings for \(title)"]
    }

    private func permissionRow(title: String, granted: Bool, onGrant: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? Color.green : Color.boost)
                    .accessibilityHidden(true)
                // Carries the row's name too, so the pair is read as one phrase.
                Text(granted ? "Granted" : "Not granted")
                    .accessibilityLabel(Self.permissionStatusLabel(title: title, granted: granted))
                if !granted {
                    Button("Turn on…", action: onGrant)
                        .controlSize(.small)
                        .accessibilityLabel("Open System Settings for \(title)")
                        .accessibilityHint("Turn on")
                        .accessibilityInputLabels(Self.turnOnInputLabels(for: title))
                }
            }
        } label: {
            Text(title)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Footer

    /// "BrightBoi 1.1.0 (3) · built-in display only", read from the bundle's
    /// Info.plist. A build without a version (`swift run`, tests) reads
    /// "BrightBoi · built-in display only".
    nonisolated static func versionLabel(info: [String: Any]?) -> String {
        var label = "BrightBoi"
        if let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            label += " \(version)"
            if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
                label += " (\(build))"
            }
        }
        return label + " · built-in display only"
    }

    /// The line under the version after a check the user asked for, or an
    /// update found by any check; `nil` when there is nothing to say.
    @MainActor
    static func updateStatusText(for updates: UpdateChecker) -> String? {
        if let update = updates.availableUpdate { return UpdateChecker.availableText(for: update) }
        switch updates.manualStatus {
        case .idle: return nil
        case .checking: return UpdateChecker.checkingText
        case .upToDate: return UpdateChecker.upToDateText
        case .failed: return UpdateChecker.failureText
        }
    }

    private func footer() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Self.versionLabel(info: Bundle.main.infoDictionary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let updates {
                        Button("Check for Updates…") {
                            Task { await updates.checkNow() }
                        }
                        .controlSize(.small)
                        .disabled(updates.manualStatus == .checking)
                    }
                }
                if let updates, let status = Self.updateStatusText(for: updates) {
                    updateStatusRow(status, updates: updates)
                }
            }
            HStack {
                Button("Support BrightBoi…", action: onShowSupport)
                Spacer()
                Button("Quit BrightBoi") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
    }

    /// The result of an update check. Only a found update is a link; a
    /// failure or "up to date" is just a line of text.
    private func updateStatusRow(_ text: String, updates: UpdateChecker) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            if updates.availableUpdate != nil {
                Button("View release") { updates.openAvailableUpdate() }
                    .controlSize(.small)
                    .accessibilityHint("Opens the download page in your browser")
            }
        }
    }

    // MARK: - Shared row building blocks

    /// A real labelled switch: the title names it for assistive technology,
    /// and the subtitle is its help text.
    private func toggleRow(title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
    }

    private func shortcutRow(press: BrightnessController.KeyPress, combo: KeyCombo) -> some View {
        LabeledContent(press.label) {
            ShortcutPill(press: press, combo: combo, recorder: recorder)
        }
    }

    /// Shown only while the shortcut differs from the default, so there is
    /// always a way back to F1/F2.
    private func resetShortcutRow() -> some View {
        HStack {
            Spacer()
            Button("Reset to F1/F2") {
                controller.resetKeyRemapShortcut()
            }
            .controlSize(.small)
            .accessibilityHint("Restores F1 for Lower and F2 for Raise")
        }
    }
}
