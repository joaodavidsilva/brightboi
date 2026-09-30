import SwiftUI

/// A single advisory row with an icon and a sentence, optionally followed by
/// an action. Two looks: amber for what needs the user's action or degrades
/// behaviour, neutral for what only informs.
struct AdvisoryBanner<Accessory: View>: View {
    enum Style {
        /// Needs action, or something works worse than expected.
        case attention
        /// Purely informational.
        case info
    }

    var style: Style
    var icon: String
    var text: String
    @ViewBuilder var accessory: Accessory

    init(style: Style = .attention, icon: String, text: String, @ViewBuilder accessory: () -> Accessory) {
        self.style = style
        self.icon = icon
        self.text = text
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: Theme.GlyphSize.inline))
                .foregroundStyle(style == .attention ? Color.boostText : Color.textSecondary)
                // A fixed column, so the text lines up across banners whose
                // symbols differ in width.
                .frame(width: 14, alignment: .center)
            Text(text)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.textRow)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            accessory
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            style == .attention ? Color.boostFill : Color.fillGrouped,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card)
        )
        .contrastBorder(cornerRadius: Theme.Radius.card)
    }
}

extension AdvisoryBanner where Accessory == EmptyView {
    init(style: Style = .attention, icon: String, text: String) {
        self.init(style: style, icon: icon, text: text) { EmptyView() }
    }
}
