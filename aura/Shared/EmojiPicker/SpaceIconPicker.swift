import SwiftUI

enum SpaceIconSelection {
    case emoji(String)
    case symbol(name: String, colorHex: String?)
    /// Recolours the already-chosen symbol without closing the picker.
    case color(String?)
}

/// Icon or emoji picker for a space. Icons are a curated SF Symbol set with a
/// colour swatch row; emoji reuse the bundled set, base forms only.
struct SpaceIconPicker: View {
    let initialSymbol: String?
    let initialColorHex: String?
    let onSelect: (SpaceIconSelection) -> Void

    @Environment(\.theme) private var theme
    @StateObject private var emojiModel = EmojiViewModel()
    @State private var mode: PickerMode
    @State private var search: String = ""
    @State private var colorHex: String?
    @State private var selectedSymbol: String?
    @State private var hoveredSymbol: String?

    private enum PickerMode: String, CaseIterable {
        case icons = "Icons"
        case emoji = "Emoji"
    }

    init(
        initialSymbol: String? = nil,
        initialColorHex: String? = nil,
        onSelect: @escaping (SpaceIconSelection) -> Void
    ) {
        self.initialSymbol = initialSymbol
        self.initialColorHex = initialColorHex
        self.onSelect = onSelect
        _mode = State(initialValue: initialSymbol == nil ? .emoji : .icons)
        _colorHex = State(initialValue: initialColorHex)
        _selectedSymbol = State(initialValue: initialSymbol)
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(PickerMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            SearchBar(text: $search)
                .frame(height: 36)
                .onChange(of: search) { _, newValue in emojiModel.searchText = newValue }

            if mode == .icons {
                swatchRow
                symbolGrid
            } else {
                EmojiGridView(viewModel: emojiModel, onSelect: { onSelect(.emoji($0)) })
                if search.isEmpty { categoryRow }
            }
        }
        .frame(width: 400, height: 400)
        .padding(8)
        .overlay {
            if mode == .emoji, let error = emojiModel.error {
                Text("Error: \(error)").foregroundColor(.red)
            }
        }
    }

    // MARK: - Icons

    private var swatchRow: some View {
        HStack(spacing: 6) {
            swatch(hex: nil)
            ForEach(SpaceIconCatalog.palette, id: \.self) { swatch(hex: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func swatch(hex: String?) -> some View {
        let isSelected = colorHex == hex
        return Circle()
            .fill(SpaceIconCatalog.color(hex: hex) ?? theme.foreground)
            .frame(width: 18, height: 18)
            .overlay(
                Circle().stroke(theme.foreground.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                    .padding(-3)
            )
            .contentShape(Circle())
            .help(hex ?? "Auto")
            .onTapGesture {
                colorHex = hex
                if selectedSymbol != nil { onSelect(.color(hex)) }
            }
    }

    private var symbolGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 4)], spacing: 4) {
                ForEach(SpaceIconCatalog.search(search)) { symbol in
                    Image(systemName: symbol.name)
                        .font(.system(size: 20))
                        .foregroundColor(SpaceIconCatalog.color(hex: colorHex) ?? theme.foreground)
                        .frame(width: 36, height: 36)
                        .background(hoveredSymbol == symbol.name ? theme.mutedBackground : Color.clear)
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onHover { hoveredSymbol = $0 ? symbol.name : nil }
                        .onTapGesture {
                            selectedSymbol = symbol.name
                            onSelect(.symbol(name: symbol.name, colorHex: colorHex))
                        }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Emoji categories

    private var categoryRow: some View {
        HStack {
            Spacer()
            ForEach(emojiModel.categories) { category in
                Button {
                    emojiModel.selectedCategory = category.category
                } label: {
                    Image(systemName: categoryIcon(for: category.category))
                        .font(.system(size: 16))
                        .foregroundColor(
                            emojiModel.selectedCategory == category.category ? theme.accent : theme.mutedForeground
                        )
                }
                .buttonStyle(.interactive(cornerRadius: 6))
                .padding(4)
                Spacer()
            }
        }
    }

    private func categoryIcon(for category: String) -> String {
        switch category.lowercased() {
        case let str where str.contains("smileys"): return "face.smiling.inverse"
        case let str where str.contains("animals"): return "pawprint"
        case let str where str.contains("food"): return "fork.knife"
        case let str where str.contains("travel"): return "sun.max"
        case let str where str.contains("objects"): return "gift"
        case let str where str.contains("symbols"): return "heart"
        case let str where str.contains("flags"): return "flag"
        default: return "questionmark"
        }
    }
}
