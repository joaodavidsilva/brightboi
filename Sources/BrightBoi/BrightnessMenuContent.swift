import AppKit
import SwiftUI

/// The dropdown shown when the menu bar icon is clicked: one continuous
/// slider spanning Nominal Brightness and Extended Brightness / Boost
/// (0–200%), per the spec's "one smooth motion, not a separate mode" design.
/// Dragging below 100% is byte-identical to ticket 04's behavior; the
/// controller (not this view) owns where the Nominal/Boost boundary falls.
struct BrightnessMenuContent: View {
    var controller: BrightnessController

    var body: some View {
        VStack(spacing: 8) {
            Text("BrightBoi")
                .font(.headline)

            Slider(
                value: Binding(
                    get: { controller.currentState.percentage },
                    set: { controller.setPercentage($0) }
                ),
                in: BrightnessController.minimumPercentage...(
                    controller.currentState.supportsBoost
                        ? BrightnessController.maximumPercentage
                        : BrightnessController.nominalCeilingPercentage
                ),
                step: BrightnessController.percentageGranularity
            )

            Text("\(Int(controller.currentState.percentage.rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { controller.currentState.launchAtLoginEnabled },
                    set: { controller.setLaunchAtLoginEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)

            Button("Quit BrightBoi") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 220)
    }
}
