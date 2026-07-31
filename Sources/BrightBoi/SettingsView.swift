import AppKit
import SwiftUI

/// BrightBoi's Settings window (mockups 1d/2d): Boost Ceiling, Key Remap
/// shortcut + on/off toggle, and a Permissions panel. Reuses
/// `BrightnessMenuContent.Palette` for appearance-aware colors — no new
/// preference, same `colorScheme`-driven approach as the popover (ticket 01).
struct SettingsView: View {
    var controller: BrightnessController
    var permissions: PermissionsSnapshot

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    private static let accessibilityPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private static let inputMonitoringPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    var body: some View {
        let state = controller.currentState
        let palette = BrightnessMenuContent.Palette(colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: 18) {
            generalSection(state: state, palette: palette)

            if state.supportsBoost {
                boostCeilingSection(state: state, palette: palette)
            }

            permissionsSection(palette: palette)

            footer(palette: palette)
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 18, trailing: 22))
        .frame(width: 480)
    }

    // MARK: - General

    private func generalSection(state: BrightnessController.State, palette: BrightnessMenuContent.Palette) -> some View {
        section(title: "General", palette: palette) {
            VStack(spacing: 0) {
                toggleRow(
                    title: "Launch at login",
                    isOn: Binding(
                        get: { state.launchAtLoginEnabled },
                        set: { controller.setLaunchAtLoginEnabled($0) }
                    ),
                    palette: palette
                )

                rowDivider(palette: palette)

                toggleRow(
                    title: remapToggleTitle(state.keyRemapShortcut),
                    subtitle: "The brightness keys step in 5% jumps across the whole 0–200% range instead of stopping at 100%.",
                    isOn: Binding(
                        get: { state.keyRemapEnabled },
                        set: { controller.setKeyRemapEnabled($0) }
                    ),
                    palette: palette
                )

                rowDivider(palette: palette)

                shortcutRow(title: "Raise", combo: state.keyRemapShortcut.raise, palette: palette) { newCombo in
                    controller.setKeyRemapShortcut(KeyRemapShortcut(raise: newCombo, lower: state.keyRemapShortcut.lower))
                }

                rowDivider(palette: palette)

                shortcutRow(title: "Lower", combo: state.keyRemapShortcut.lower, palette: palette) { newCombo in
                    controller.setKeyRemapShortcut(KeyRemapShortcut(raise: state.keyRemapShortcut.raise, lower: newCombo))
                }
            }
            .background(palette.quickSetBackground, in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func remapToggleTitle(_ shortcut: KeyRemapShortcut) -> String {
        shortcut == .defaultShortcut
            ? "Let BrightBoi own F1 / F2"
            : "Let BrightBoi own \(shortcut.raise.displayString) / \(shortcut.lower.displayString)"
    }

    // MARK: - Boost Ceiling

    private func boostCeilingSection(state: BrightnessController.State, palette: BrightnessMenuContent.Palette) -> some View {
        section(title: "Boost ceiling", palette: palette) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .lastTextBaseline) {
                    Text("Don't let me go past")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.rowText)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("\(Int(state.boostCeiling))%")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text("· \(Int(state.boostCeilingNits)) nits")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.secondaryText)
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
                .tint(palette.quickSetMaxText)

                HStack {
                    Text("100%")
                    Spacer()
                    Text("200% · 1000 nits")
                }
                .font(.system(size: 10))
                .foregroundStyle(palette.tertiaryText)

                Text("200% is the panel's sustained full-screen rating. BrightBoi won't offer more than that, no matter how nicely you ask.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(13)
            .background(palette.quickSetBackground, in: RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: - Permissions

    private func permissionsSection(palette: BrightnessMenuContent.Palette) -> some View {
        section(title: "Permissions", palette: palette) {
            VStack(alignment: .leading, spacing: 4) {
                VStack(spacing: 0) {
                    permissionRow(title: "Accessibility", granted: permissions.accessibilityGranted, paneURL: Self.accessibilityPaneURL, palette: palette)
                    rowDivider(palette: palette)
                    permissionRow(title: "Input Monitoring", granted: permissions.inputMonitoringGranted, paneURL: Self.inputMonitoringPaneURL, palette: palette)
                }
                .background(palette.quickSetBackground, in: RoundedRectangle(cornerRadius: 9))

                Text("Without both, the slider still works — the configured keys just go back to macOS's native handling.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    private func permissionRow(title: String, granted: Bool, paneURL: URL, palette: BrightnessMenuContent.Palette) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(palette.rowText)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(granted ? "Granted" : "Not granted")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
            }
            if !granted {
                Button("Open System Settings") {
                    openURL(paneURL)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.rowText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(palette.quickSetMaxBackground, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private func footer(palette: BrightnessMenuContent.Palette) -> some View {
        HStack {
            Text("BrightBoi 1.0 · built-in display only")
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryText)
            Spacer()
            Button("Quit BrightBoi") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.rowText)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(palette.quickSetBackground, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Shared row building blocks

    private func section(title: String, palette: BrightnessMenuContent.Palette, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(palette.tertiaryText)
            content()
        }
    }

    private func toggleRow(title: String, subtitle: String? = nil, isOn: Binding<Bool>, palette: BrightnessMenuContent.Palette) -> some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.rowText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryText)
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

    private func shortcutRow(title: String, combo: KeyCombo, palette: BrightnessMenuContent.Palette, onChange: @escaping (KeyCombo) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(palette.rowText)
            Spacer()
            ShortcutRecorderView(combo: combo, palette: palette, onChange: onChange)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    private func rowDivider(palette: BrightnessMenuContent.Palette) -> some View {
        Rectangle()
            .fill(palette.divider)
            .frame(height: 0.5)
            .padding(.leading, 13)
    }
}

/// A small clickable pill that records the next key combination pressed
/// while active — used for both the Raise and Lower rows. Rejects (per
/// ADR-0007) any combo without a modifier key unless it's F1/F2 itself,
/// briefly showing a rejection hint instead of applying it.
private struct ShortcutRecorderView: View {
    var combo: KeyCombo
    var palette: BrightnessMenuContent.Palette
    var onChange: (KeyCombo) -> Void

    @State private var isRecording = false
    @State private var isRejecting = false
    @State private var localMonitor: Any?

    private static let escapeKeyCode: UInt16 = 0x35

    var body: some View {
        Button {
            startRecording()
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isRejecting ? Color.red : palette.rowText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(palette.quickSetBackground, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if isRejecting { return "Needs a modifier" }
        if isRecording { return "Press a key…" }
        return combo.displayString
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            stopRecording()

            guard event.keyCode != Self.escapeKeyCode else { return nil }

            let candidate = KeyCombo(
                modifiers: KeyCombo.Modifiers(nsEventModifierFlags: event.modifierFlags),
                keyCode: Int64(event.keyCode)
            )

            if candidate.isValidRemap {
                onChange(candidate)
            } else {
                flashRejection()
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }

    private func flashRejection() {
        isRejecting = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            isRejecting = false
        }
    }
}
