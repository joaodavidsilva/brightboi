import SwiftUI

/// A popover action row that highlights like a system menu row: a soft
/// rounded fill while the pointer is over it and a stronger one while it is
/// pressed. The highlight reaches 8pt past the row on each side, into the
/// popover's padding, without moving the row's content.
struct MenuRowButtonStyle: ButtonStyle {
    static let cornerRadius: CGFloat = 6
    static let highlightOutset: CGFloat = 8

    /// How strongly the row is tinted.
    static func highlightOpacity(isPressed: Bool, isHovered: Bool) -> Double {
        isPressed ? 0.15 : (isHovered ? 0.08 : 0)
    }

    func makeBody(configuration: Configuration) -> some View {
        MenuRow(isPressed: configuration.isPressed) { configuration.label }
    }

    /// Holds the hover state, which a `ButtonStyle` cannot keep itself.
    private struct MenuRow<Content: View>: View {
        var isPressed: Bool
        @ViewBuilder var content: Content
        @State private var isHovered = false

        var body: some View {
            content
                .padding(.horizontal, MenuRowButtonStyle.highlightOutset)
                .background(
                    RoundedRectangle(cornerRadius: MenuRowButtonStyle.cornerRadius)
                        .fill(Color.primary.opacity(MenuRowButtonStyle.highlightOpacity(isPressed: isPressed, isHovered: isHovered)))
                )
                .contentShape(RoundedRectangle(cornerRadius: MenuRowButtonStyle.cornerRadius))
                .padding(.horizontal, -MenuRowButtonStyle.highlightOutset)
                .onHover { isHovered = $0 }
        }
    }
}
