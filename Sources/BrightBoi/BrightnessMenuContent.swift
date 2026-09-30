import AppKit
import SwiftUI

/// The dropdown shown when the menu bar icon is clicked: one continuous
/// slider spanning Nominal Brightness and Extended Brightness / Boost
/// (0–200%), as one smooth motion rather than a separate mode. The
/// controller (not this view) owns where the Nominal/Boost boundary falls.
///
/// A custom-drawn track replaces the stock `Slider` because the stock control
/// can't render the boost-zone stripe hint, the two-tone fill, or the
/// boundary tick. Colours, type sizes and radii come from `Theme`.
struct BrightnessMenuContent: View {
    var controller: BrightnessController

    /// A comfortable low-light level, rather than an arbitrary round number.
    private static let dimPercentage: Double = 40

    var body: some View {
        let state = controller.currentState

        VStack(alignment: .leading, spacing: 12) {
            header(state: state)
            readout(state: state)

            VStack(alignment: .leading, spacing: 2) {
                BoostSlider(
                    percentage: state.percentage,
                    supportsBoost: state.supportsBoost,
                    onChange: { controller.setPercentageFromDrag($0) }
                )
                rangeCaptions()
            }

            quickSetRow(state: state)

            if hasAdvisories(state: state) {
                advisories(state: state)
            }

            ThemeDivider()
                .padding(.horizontal, -14)

            actionsList()
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 8, trailing: 14))
        .frame(width: 280)
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

    private func header(state: BrightnessController.State) -> some View {
        HStack {
            HStack(spacing: 7) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: Theme.GlyphSize.header))
                    .foregroundStyle(Color.textPrimary)
                Text("BrightBoi")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
            }
            Spacer()
            if state.isBoosted {
                Text("BOOSTED")
                    .font(Theme.Typography.badge)
                    .tracking(0.3)
                    .foregroundStyle(Color.boostText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.boostFill, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                    .contrastBorder(cornerRadius: Theme.Radius.badge)
            } else if state.isBoostPaused {
                Text("BOOST PAUSED")
                    .font(Theme.Typography.badge)
                    .tracking(0.3)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.fillGrouped, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                    .contrastBorder(cornerRadius: Theme.Radius.badge)
            }
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
    }

    private func rangeCaptions() -> some View {
        HStack {
            Text("0")
            Spacer()
            Text("100% · ~500 nits")
            Spacer()
            Text("200%")
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Color.textTertiary)
    }

    private func quickSetRow(state: BrightnessController.State) -> some View {
        HStack(spacing: 6) {
            quickSetButton(title: "Dim", isPrimary: false) {
                controller.setPercentage(Self.dimPercentage)
            }
            quickSetButton(title: "100%", isPrimary: false) {
                controller.setPercentage(BrightnessController.nominalCeilingPercentage)
            }
            quickSetButton(title: "Max boi", isPrimary: true) {
                controller.setPercentage(BrightnessController.effectiveMaximum(supportsBoost: state.supportsBoost))
            }
        }
    }

    private func quickSetButton(
        title: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(isPrimary ? Theme.Typography.callout.weight(.semibold) : Theme.Typography.control)
        }
        .buttonStyle(PillButtonStyle(
            fill: isPrimary ? .boostFill : .fillGrouped,
            foreground: isPrimary ? .boostText : .textPrimary,
            cornerRadius: Theme.Radius.button,
            horizontalPadding: 0,
            verticalPadding: 6,
            fillsWidth: true
        ))
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

    /// Banners that need the user's action, or that say something works worse
    /// than expected (Key Remap down, Nominal control unavailable, Boost
    /// blocked, battery, thermal), are amber. The rest only inform (display
    /// off, Boost paused, Low Power Mode) and are neutral. None of them ever
    /// blocks or clamps the slider. `batteryAdvisoryVisible` already excludes
    /// itself whenever the Low Power Mode banner is showing, so at most one
    /// power-related banner ever appears at once.
    private func advisories(state: BrightnessController.State) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isKeyRemapDown(state: state) {
                AdvisoryBanner(
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
                    icon: "bolt.slash.fill",
                    // Generic copy, no time-remaining estimate — no battery
                    // consumption model exists to make that number real.
                    text: "Above \(Int(BrightnessController.batteryAdvisoryThresholdPercentage))% eats battery fast — you're not plugged in."
                )
            }
            if let thermalAdvisory = controller.thermalAdvisory {
                AdvisoryBanner(
                    icon: "thermometer.high",
                    text: "Running hot — delivering closer to \(Int(thermalAdvisory.deliveredPercentage.rounded()))% than the \(Int(thermalAdvisory.requestedPercentage.rounded()))% requested."
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

    private func actionsList() -> some View {
        VStack(spacing: 0) {
            SettingsLink {
                actionRow(title: "Settings…", shortcut: "⌘,")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                actionRow(title: "Quit BrightBoi", shortcut: "⌘Q")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func actionRow(title: String, shortcut: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textTertiary)
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Color.textRow)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// The custom track replacing the stock `Slider`:
/// a base track, a diagonal-stripe hint over the unfilled boost zone (only
/// when `supportsBoost`), a solid nominal fill, a gradient boost fill, a
/// tick at the Nominal/Boost boundary, and a plain circular knob.
private struct BoostSlider: View {
    var percentage: Double
    var supportsBoost: Bool
    var onChange: (Double) -> Void

    private static let trackHeight: CGFloat = 6
    private static let knobDiameter: CGFloat = 18
    private static let rowHeight: CGFloat = 26

    private var effectiveMaximum: Double {
        BrightnessController.effectiveMaximum(supportsBoost: supportsBoost)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = percentage / effectiveMaximum
            let knobX = width * fraction
            // The boundary only exists partway across the track when Boost
            // is reachable; otherwise Nominal fills the entire track. Drawn
            // at the literal midpoint because the track always spans the
            // full 0...200 domain regardless of a personal Boost Ceiling
            // — only how far the *fill* is allowed to travel
            // changes there, not where 100% sits on the track itself.
            let boundaryX = supportsBoost ? width / 2 : width
            let trackY = (Self.rowHeight - Self.trackHeight) / 2

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Self.trackHeight / 2)
                    .fill(Color.fillTrack)
                    .frame(width: width, height: Self.trackHeight)
                    .offset(y: trackY)

                if supportsBoost {
                    DiagonalStripes()
                        .stroke(Color.boostStripe, lineWidth: 3)
                        .frame(width: width - boundaryX, height: Self.trackHeight)
                        .offset(x: boundaryX, y: trackY)
                }

                RoundedRectangle(cornerRadius: Self.trackHeight / 2)
                    .fill(Color.sliderNominal)
                    .frame(width: min(knobX, boundaryX), height: Self.trackHeight)
                    .offset(y: trackY)

                if supportsBoost && knobX > boundaryX {
                    Rectangle()
                        .fill(LinearGradient(colors: [Color.boostHighlight, Color.boost], startPoint: .leading, endPoint: .trailing))
                        .frame(width: knobX - boundaryX, height: Self.trackHeight)
                        .offset(x: boundaryX, y: trackY)
                }

                if supportsBoost {
                    Rectangle()
                        .fill(Color.sliderTick)
                        .frame(width: 1.5, height: 14)
                        .offset(x: boundaryX - 0.75, y: Self.rowHeight / 2 - 7)
                }

                Circle()
                    .fill(Color.sliderKnob)
                    .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                    .shadow(color: Color.sliderKnobShadow, radius: 2, y: 1)
                    .offset(x: knobX - Self.knobDiameter / 2, y: (Self.rowHeight - Self.knobDiameter) / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clampedX = min(max(value.location.x, 0), width)
                        onChange((clampedX / width) * effectiveMaximum)
                    }
            )
        }
        .frame(height: Self.rowHeight)
    }
}

/// Repeating diagonal lines: the stripe hint drawn over the not-yet-reached
/// boost zone.
private struct DiagonalStripes: Shape {
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
