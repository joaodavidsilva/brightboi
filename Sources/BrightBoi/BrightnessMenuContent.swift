import SwiftUI

/// The dropdown shown when the menu bar icon is clicked. Ticket 04 exposes
/// only the Nominal Brightness range (0–100%) — Boost's 100–200% is ticket
/// 05's UI to add, per that ticket's explicit scope boundary.
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
                in: BrightnessController.minimumPercentage...BrightnessController.nominalCeilingPercentage
            )

            Text("\(Int(controller.currentState.percentage.rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 220)
    }
}
