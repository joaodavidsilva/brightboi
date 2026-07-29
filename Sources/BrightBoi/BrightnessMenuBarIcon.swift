import SwiftUI

/// The menu bar label: a sun glyph that fills from the bottom in proportion
/// to `BrightnessController.State.iconFillFraction`, so it visibly tracks
/// the slider live.
///
/// Empirically verified (throwaway `ImageRenderer` probe, not shipped) that
/// SF Symbols' `Image(systemName:variableValue:)` renders byte-identical
/// output across fractions for `sun.max` / `sun.max.fill` — that symbol has
/// no variable-color layers, so `variableValue` is silently ignored. This
/// masked-fill composition was confirmed to render distinctly across
/// fractions instead.
///
/// `iconFillFraction` spans the full 0...200% range (`percentage / 200`, per
/// ticket 03), so within ticket 04's 0–100% UI this only ever reaches half
/// fill — intentional per the spec's single continuous slider design (spec
/// Implementation Decisions: the icon renderer consumes the controller's
/// derived fraction rather than recomputing its own), signaling there's more
/// headroom above once ticket 05 exposes Boost.
struct BrightnessMenuBarIcon: View {
    var controller: BrightnessController

    var body: some View {
        ZStack {
            Image(systemName: "sun.max")
                .opacity(0.35)
            Image(systemName: "sun.max.fill")
                .mask(alignment: .bottom) {
                    GeometryReader { proxy in
                        Rectangle()
                            .frame(height: proxy.size.height * controller.currentState.iconFillFraction)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
        }
    }
}
