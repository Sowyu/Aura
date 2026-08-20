import SwiftUI

/// Grid of base emoji only. Emoji with skin-tone or hair forms open a small
/// variant strip instead of committing straight away.
struct EmojiGridView: View {
    @ObservedObject var viewModel: EmojiViewModel
    let onSelect: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var hoveredEmoji: String?
    @State private var variantItemID: UUID?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 4)], spacing: 4) {
                ForEach(viewModel.filteredEmojis) { item in
                    cell(for: item)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cell(for item: EmojiItem) -> some View {
        emojiTile(item.emoji, size: 16)
            .onTapGesture {
                if item.variants.isEmpty {
                    onSelect(item.emoji)
                } else {
                    variantItemID = item.id
                }
            }
            .popover(isPresented: variantBinding(for: item), arrowEdge: .bottom) {
                variantStrip(for: item)
            }
    }

    private func variantBinding(for item: EmojiItem) -> Binding<Bool> {
        Binding(
            get: { variantItemID == item.id },
            set: { if !$0, variantItemID == item.id { variantItemID = nil } }
        )
    }

    private func variantStrip(for item: EmojiItem) -> some View {
        let forms = [item] + item.variants
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 6), spacing: 4) {
            ForEach(forms) { form in
                emojiTile(form.emoji, size: 18)
                    .onTapGesture {
                        variantItemID = nil
                        onSelect(form.emoji)
                    }
            }
        }
        .padding(8)
        .frame(width: 232)
    }

    private func emojiTile(_ emoji: String, size: CGFloat) -> some View {
        Text(emoji)
            .font(.system(size: size))
            .frame(width: 32, height: 32)
            .background(hoveredEmoji == emoji ? theme.mutedBackground : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
            .onHover { hoveredEmoji = $0 ? emoji : nil }
    }
}

/// Custom Search Bar
struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            TextField("Search", text: $text)
                .textFieldStyle(PlainTextFieldStyle())
                .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(8)
    }
}
