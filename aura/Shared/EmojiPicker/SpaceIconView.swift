import SwiftUI

/// The single place a space's icon is drawn: a bundled glyph tinted with the chosen
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
            glyph(symbol)
                .foregroundStyle(SpaceIconCatalog.color(hex: colorHex) ?? theme.foreground)
        } else {
            Text(emoji)
                .font(.system(size: size))
        }
    }

    /// Saved spaces may hold an SF Symbol name from the old catalog, so try the bundled
    /// glyph, then the legacy mapping, and only then SF Symbols.
    @ViewBuilder
    private func glyph(_ symbol: String) -> some View {
        let legacy = SpaceIconCatalog.legacySymbolMap[symbol]
        if let image = SpaceIconImage.load(symbol) ?? legacy.flatMap(SpaceIconImage.load) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size))
        }
    }
}
