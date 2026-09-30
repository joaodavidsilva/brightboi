import AppKit
import SwiftUI

/// The dropdown shown when the menu bar icon is clicked: one continuous
/// slider spanning Nominal Brightness and Extended Brightness / Boost
/// (0–200%), as one smooth motion rather than a separate mode. The
/// controller (not this view) owns where the Nominal/Boost boundary falls.
///
/// A custom-drawn track replaces the stock `Slider` because the stock control
/// can't render the boost-zone stripe hint, the two-tone fill, or the
/// boundary cut. Colours, type sizes and radii come from `Theme`.
struct BrightnessMenuContent: View {
    var controller: BrightnessController
    /// The update check. `nil` where there is none (previews and tests).
    var updates: UpdateChecker?

    @Environment(\.openSettings) private var openSettings

    /// A comfortable low-light level, rather than an arbitrary round number.
    private static let dimPercentage: Double = 40

    var body: some View {
        let state = controller.currentState

        VStack(alignment: .leading, spacing: 12) {
            PopoverHeader(isBoosted: state.isBoosted, isBoostPaused: state.isBoostPaused)

            // With the built-in display off none of these do anything, so
            // they are dimmed and stop taking clicks until it is back.
            let controlsEnabled = Self.controlsEnabled(for: state)
            Group {
                readout(state: state)

                VStack(alignment: .leading, spacing: 2) {
                    BoostSlider(
                        percentage: state.percentage,
                        supportsBoost: state.supportsBoost,
                        boostCeiling: state.boostCeiling,
                        isEnabled: controlsEnabled,
                        onChange: { controller.setPercentageFromDrag($0) }
                    )
                    rangeCaptions(supportsBoost: state.supportsBoost)
                }

                quickSetRow(state: state)
            }
            .opacity(controlsEnabled ? 1 : 0.45)
            .allowsHitTesting(controlsEnabled)
            .disabled(!controlsEnabled)

            if hasAdvisories(state: state) {
                advisories(state: state)
            }

            if let updates {
                updateRows(updates)
            }

            ThemeDivider()
                .padding(.horizontal, -14)

            actionsList()
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 8, trailing: 14))
        .frame(width: 280)
        // A warning that appears while the popover is open is announced once,
        // when it appears, rather than each time the view is drawn.
        .onChange(of: controller.batteryAdvisoryVisible) { _, visible in
            if visible { AccessibilityNotification.Announcement(Self.batteryAdvisorySpokenLabel).post() }
        }
        .onChange(of: controller.thermalAdvisory != nil) { _, visible in
            if visible, let advisory = controller.thermalAdvisory {
                AccessibilityNotification.Announcement(Self.thermalAdvisorySpokenLabel(advisory)).post()
            }
        }
        .onAppear {
            controller.syncFromDisplay()
            controller.permissionsMayHaveChanged()
        }
        // `MenuBarExtra(.window)` keeps this content's hosting view alive
        // between openings, so `onAppear` alone isn't guaranteed to fire on
        // every reopen — pairing it with the app becoming active (which
        // showing the popover typically triggers) catches the reopen case
        // `onAppear` might miss.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.syncFromDisplay()
            controller.permissionsMayHaveChanged()
        }
    }

    private func readout(state: BrightnessController.State) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text("\(Int(state.percentage.rounded()))%")
                .font(Theme.Typography.display)
                .foregroundStyle(Color.textPrimary)
            Text("~\(Int(state.nits.rounded())) nits")
                .font(Theme.Typography.callout.monospacedDigit())
                .foregroundStyle(Color.textSecondary)
        }
        // The slider carries the value for VoiceOver.
        .accessibilityHidden(true)
    }

    /// Whether the slider, readout and quick-set buttons do anything: not
    /// while the built-in display is off.
    static func controlsEnabled(for state: BrightnessController.State) -> Bool {
        state.builtInDisplayAvailable
    }

    /// The end labels sit at the row's edges and the middle label is centred
    /// on the full width, which is exactly where 100% falls on a track that
    /// spans 0-200%. Without Boost the track ends at 100% and there is no
    /// middle label.
    private func rangeCaptions(supportsBoost: Bool) -> some View {
        ZStack {
            HStack {
                Text("0%")
                Spacer()
                Text(supportsBoost ? "200%" : "100%")
            }
            if supportsBoost {
                Text("100% · ~500 nits")
            }
        }
        .font(Theme.Typography.caption.monospacedDigit())
        .foregroundStyle(Color.textTertiary)
        .accessibilityHidden(true)
    }

    /// One quick-set button.
    struct QuickSetPreset: Equatable {
        var title: String
        var percentage: Double
        var isBoost: Bool
    }

    /// The quick-set buttons for a display. Without Boost, "100%" is the
    /// top of the range, so there is no "Max boi" and no amber. With Boost,
    /// "Max boi" aims at the top of the track; the controller holds it at the
    /// Boost Ceiling.
    static func quickSetPresets(supportsBoost: Bool) -> [QuickSetPreset] {
        var presets = [
            QuickSetPreset(title: "Dim", percentage: dimPercentage, isBoost: false),
            QuickSetPreset(title: "100%", percentage: BrightnessController.nominalCeilingPercentage, isBoost: false)
        ]
        if supportsBoost {
            presets.append(QuickSetPreset(
                title: "Max boi",
                percentage: BrightnessController.effectiveMaximum(supportsBoost: true),
                isBoost: true
            ))
        }
        return presets
    }

    private func quickSetRow(state: BrightnessController.State) -> some View {
        HStack(spacing: 6) {
            ForEach(Self.quickSetPresets(supportsBoost: state.supportsBoost), id: \.title) { preset in
                quickSetButton(
                    title: preset.title,
                    isPrimary: preset.isBoost,
                    hint: Self.quickSetHint(
                        preset: preset,
                        supportsBoost: state.supportsBoost,
                        boostCeiling: state.boostCeiling
                    )
                ) {
                    controller.setPercentage(preset.percentage)
                }
            }
        }
    }

    /// What a quick-set button will really set: its target, held at the
    /// level the display can reach (the Boost Ceiling, or 100% without Boost).
    static func quickSetTarget(preset: QuickSetPreset, supportsBoost: Bool, boostCeiling: Double) -> Double {
        let reachable = supportsBoost ? boostCeiling : BrightnessController.nominalCeilingPercentage
        return min(preset.percentage, reachable)
    }

    static func quickSetHint(preset: QuickSetPreset, supportsBoost: Bool, boostCeiling: Double) -> String {
        let target = quickSetTarget(preset: preset, supportsBoost: supportsBoost, boostCeiling: boostCeiling)
        return "Sets brightness to \(Int(target.rounded())) percent"
    }

    private func quickSetButton(
        title: String,
        isPrimary: Bool,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(isPrimary ? Theme.Typography.callout.weight(.semibold) : Theme.Typography.control)
        }
        .accessibilityHint(hint)
        .accessibilityInputLabels(Self.quickSetInputLabels(title: title))
        .buttonStyle(PillButtonStyle(
            fill: isPrimary ? .boostFill : .fillGrouped,
            foreground: isPrimary ? .boostText : .textPrimary,
            cornerRadius: Theme.Radius.button,
            horizontalPadding: 0,
            verticalPadding: 6,
            fillsWidth: true
        ))
    }

    /// What Voice Control accepts for a quick-set button: its visible title,
    /// plus a plainer name for the top one.
    static func quickSetInputLabels(title: String) -> [String] {
        title == "Max boi" ? ["Max boi", "Maximum brightness"] : [title]
    }

    /// Whether anything below the quick-set row has something to say. The
    /// HDR footnote counts: it is shown only while Boost is actually on.
    private func hasAdvisories(state: BrightnessController.State) -> Bool {
        isKeyRemapDown(state: state)
            || state.boostBlockedByOtherApp
            || state.isBoostPaused
            || state.isBoosted
            || !state.builtInDisplayAvailable
            || !state.nominalControlAvailable
            || controller.batteryAdvisoryVisible
            || controller.thermalAdvisory != nil
            || controller.isLowPowerModeAdvisoryVisible
    }

    /// Key Remap is on but its tap is not running.
    private func isKeyRemapDown(state: BrightnessController.State) -> Bool {
        state.keyRemapEnabled && !controller.keyRemapActive
    }

    /// Amber is kept for refusals and failures: Boost blocked by another app
    /// and Nominal control unavailable. Everything else only informs (Key
    /// Remap inactive, display off, Boost paused, Low Power Mode, battery,
    /// thermal) and is neutral. None of them ever blocks or clamps the
    /// slider. `batteryAdvisoryVisible` already excludes itself whenever the
    /// Low Power Mode banner is showing, so at most one power-related banner
    /// ever appears at once.
    private func advisories(state: BrightnessController.State) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isKeyRemapDown(state: state) {
                AdvisoryBanner(
                    style: .info,
                    icon: "keyboard",
                    text: "Key Remap isn't active, so the brightness keys stay with macOS. Open Settings to fix it."
                )
            }
            if !state.builtInDisplayAvailable {
                AdvisoryBanner(
                    style: .info,
                    icon: "display",
                    text: "The built-in display is off. BrightBoi leaves the brightness keys to macOS until it is back."
                )
            } else if let message = Self.nominalControlMessage(for: state.nominalControlStatus) {
                AdvisoryBanner(icon: "exclamationmark.triangle.fill", text: message)
            }
            if state.isBoostPaused {
                AdvisoryBanner(
                    style: .info,
                    icon: "circle.lefthalf.filled",
                    text: "Boost paused — Invert Colors is on. Turn it off to bring Boost back."
                )
            }
            if state.boostBlockedByOtherApp {
                AdvisoryBanner(
                    icon: "exclamationmark.triangle.fill",
                    text: "Another app is already boosting this display."
                )
            }
            if controller.isLowPowerModeAdvisoryVisible {
                AdvisoryBanner(
                    style: .info,
                    icon: "bolt.fill",
                    text: "Low Power Mode is on — Boost above 100% uses extra power."
                )
            }
            if controller.batteryAdvisoryVisible {
                AdvisoryBanner(
                    style: .info,
                    icon: "bolt.slash.fill",
                    // Generic copy, no time-remaining estimate — no battery
                    // consumption model exists to make that number real.
                    text: Self.batteryAdvisoryText,
                    spokenLabel: Self.batteryAdvisorySpokenLabel
                )
            }
            if let thermalAdvisory = controller.thermalAdvisory {
                AdvisoryBanner(
                    style: .info,
                    icon: "thermometer.high",
                    text: Self.thermalAdvisoryText(thermalAdvisory),
                    spokenLabel: Self.thermalAdvisorySpokenLabel(thermalAdvisory)
                )
            }
            if state.isBoosted && state.builtInDisplayAvailable {
                // Boost scales the whole display, HDR included; nothing can
                // be done about it, so it is a footnote, not a warning.
                Text("While boosted, HDR video and photos lose their brightest highlights.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// An update that was found, or the one-time question about checking
    /// automatically. Both only inform, so they use the neutral banner style,
    /// never the amber one.
    @ViewBuilder
    private func updateRows(_ updates: UpdateChecker) -> some View {
        if let update = updates.availableUpdate {
            Button {
                updates.openAvailableUpdate()
            } label: {
                AdvisoryBanner(
                    style: .info,
                    icon: "arrow.down.circle",
                    text: UpdateChecker.availableText(for: update)
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the download page in your browser")
            .accessibilityAddTraits(.isLink)
        }
        if updates.shouldOfferConsent {
            VStack(alignment: .leading, spacing: 6) {
                AdvisoryBanner(
                    style: .info,
                    icon: "arrow.triangle.2.circlepath",
                    text: UpdateChecker.consentText
                )
                HStack(spacing: 6) {
                    consentButton(title: "Yes", enable: true, updates: updates)
                    consentButton(title: "No", enable: false, updates: updates)
                }
            }
        }
    }

    private func consentButton(title: String, enable: Bool, updates: UpdateChecker) -> some View {
        Button(title) {
            updates.setAutomaticChecksEnabled(enable)
        }
        .buttonStyle(PillButtonStyle(
            fill: .fillGrouped,
            foreground: .textPrimary,
            cornerRadius: Theme.Radius.button,
            horizontalPadding: 0,
            verticalPadding: 6,
            fillsWidth: true
        ))
        .accessibilityHint(enable ? "Turns on the daily update check" : "Keeps BrightBoi from checking for updates")
    }

    static var batteryAdvisoryText: String {
        "Above \(Int(BrightnessController.batteryAdvisoryThresholdPercentage))% eats battery fast — you're not plugged in."
    }

    static var batteryAdvisorySpokenLabel: String { "Battery warning: " + batteryAdvisoryText }

    static func thermalAdvisoryText(_ advisory: BrightnessController.ThermalAdvisory) -> String {
        "Running hot — delivering closer to \(Int(advisory.deliveredPercentage.rounded()))% than the \(Int(advisory.requestedPercentage.rounded()))% requested."
    }

    static func thermalAdvisorySpokenLabel(_ advisory: BrightnessController.ThermalAdvisory) -> String {
        "Heat warning: " + thermalAdvisoryText(advisory)
    }

    /// What to tell the user when Nominal brightness cannot be set, worded
    /// for the cause. `nil` when it can.
    static func nominalControlMessage(for status: NominalControlStatus) -> String? {
        switch status {
        case .available:
            nil
        case .symbolMissing:
            "This version of macOS blocked BrightBoi's brightness control below 100%. Check for an update."
        case .lockedBySystem:
            "Brightness is locked by the current display preset."
        }
    }

    /// Brings the app forward, then opens Settings. A menu bar app is never
    /// active when its popover's row is clicked, and without activating first
    /// the Settings window can open behind whatever app is in front. The
    /// activation goes first and is injectable so this ordering is testable
    /// without touching the real app.
    static func openSettingsWindow(
        activate: () -> Void = { NSApp.activate(ignoringOtherApps: true) },
        open: () -> Void
    ) {
        activate()
        open()
    }

    private func actionsList() -> some View {
        VStack(spacing: 0) {
            Button {
                Self.openSettingsWindow { openSettings() }
            } label: {
                actionRow(title: "Settings…", shortcut: "⌘,", hint: "Command comma")
            }
            .buttonStyle(MenuRowButtonStyle())
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                actionRow(title: "Quit BrightBoi", shortcut: "⌘Q", hint: "Command Q")
            }
            .buttonStyle(MenuRowButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
        }
        // The first row's own padding would otherwise leave about 21pt below
        // the divider against 12 above it.
        .padding(.top, -6)
    }

    private func actionRow(title: String, shortcut: String, hint: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .font(Theme.Typography.body)
        .foregroundStyle(Color.textRow)
        .padding(.vertical, 6)
    }
}

/// The header: the app name and, on the right, the BOOSTED or BOOST PAUSED
/// badge. Both badges are always laid out and only their opacity changes, so
/// the header is the same height in every state and nothing below it moves
/// when the level crosses 100%.
struct PopoverHeader: View {
    var isBoosted: Bool
    var isBoostPaused: Bool

    var body: some View {
        HStack {
            HStack(spacing: 7) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: Theme.GlyphSize.header))
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityHidden(true)
                Text("BrightBoi")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
            }
            Spacer()
            ZStack(alignment: .trailing) {
                badge("BOOSTED", foreground: .boostText, fill: .boostFill)
                    .opacity(isBoosted ? 1 : 0)
                    .accessibilityHidden(!isBoosted)
                badge("BOOST PAUSED", foreground: .textSecondary, fill: .fillGrouped)
                    .opacity(isBoosted || !isBoostPaused ? 0 : 1)
                    .accessibilityHidden(isBoosted || !isBoostPaused)
            }
            .animation(.easeOut(duration: 0.15), value: isBoosted || isBoostPaused)
        }
    }

    private func badge(_ title: String, foreground: Color, fill: Color) -> some View {
        Text(title)
            .font(Theme.Typography.badge)
            .tracking(0.3)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
            .contrastBorder(cornerRadius: Theme.Radius.badge)
    }
}
