import SwiftUI

/// The single place a space's icon is drawn: an SF Symbol tinted with the chosen
/// colour when one is set, otherwise the emoji.
struct SpaceIconView: View {
    let symbol: String?
    let colorHex: String?
    let emoji: String
    let size: CGFloat

    @Environment(\.theme) private var theme

    init(container: TabContainer, size: CGFloat = 14) {
        self.init(
            symbol: container.iconSymbol,
            colorHex: container.iconColorHex,
            emoji: container.emoji,
            size: size
        )
    }

    init(symbol: String?, colorHex: String?, emoji: String, size: CGFloat = 14) {
        self.symbol = symbol
        self.colorHex = colorHex
        self.emoji = emoji
        self.size = size
    }

    var body: some View {
        if let symbol, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundColor(SpaceIconCatalog.color(hex: colorHex) ?? theme.foreground)
        } else {
            Text(emoji)
                .font(.system(size: size))
        }
    }
}
