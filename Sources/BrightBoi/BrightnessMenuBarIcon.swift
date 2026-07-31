import SwiftUI

/// The menu bar label: a sun glyph that fills from the bottom in proportion
/// to `BrightnessController.State.iconFillFraction`, so it visibly tracks
/// the slider live. No inline percentage text — the redesigned popover is
/// where the exact number lives now, so the menu bar itself stays visually
/// quiet (ticket 01).
///
/// Empirically verified (throwaway `ImageRenderer` probe, not shipped) that
/// SF Symbols' `Image(systemName:variableValue:)` renders byte-identical
/// output across fractions for `sun.max` / `sun.max.fill` — that symbol has
/// no variable-color layers, so `variableValue` is silently ignored. This
/// masked-fill composition was confirmed to render distinctly across
/// fractions instead.
///
/// `iconFillFraction` spans the full 0...200% range (`percentage / 200`, per
/// ticket 03) — at Nominal 100% this reaches exactly half fill, at Boost
/// 200% it reaches full. On a non-XDR Mac (`supportsBoost == false`, ticket
/// 02) the reachable range is only 0...100, so the controller divides by 100
/// there instead — 100% still reads as a full icon, not half.
///
/// Fill level alone doesn't satisfy spec item 3 (the icon must look visually
/// distinct once Boosted, not just "more full") — menu bar icons can be
/// template-rendered (monochrome) by macOS, so a color-only cue risks being
/// silently flattened. A small badge glyph, consuming `isBoosted` directly
/// (per the spec: the icon renderer consumes derived state, not recomputed
/// state) survives that. Manual verification on the target machine still
/// needed — this is UI, explicitly out of the controller-level test seam per
/// the spec's Testing Decisions.
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
        .overlay(alignment: .topTrailing) {
            if controller.currentState.isBoosted {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 8))
                    .offset(x: 5, y: -3)
            }
        }
    }
}
