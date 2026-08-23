import SwiftUI

struct ContainerForm: View {
    @Binding var name: String
    @Binding var emoji: String
    @Binding var iconSymbol: String?
    @Binding var iconColorHex: String?
    @Binding var isIconPickerOpen: Bool

    let onSubmit: () -> Void
    let defaultEmoji: String

    @Environment(\.theme) private var theme
    @State private var isIconPickerHovering = false
    @FocusState private var isNameFocused: Bool

    private var isEmpty: Bool { iconSymbol == nil && emoji.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            iconPickerButton
            nameTextField
        }
        .onAppear { isNameFocused = true }
    }

    private var iconPickerButton: some View {
        Button(action: {
            isIconPickerOpen.toggle()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: ContainerConstants.UI.cornerRadius, style: .continuous)
                    .stroke(
                        theme.border,
                        style: isEmpty
                            ? StrokeStyle(lineWidth: 1, dash: [5])
                            : StrokeStyle(lineWidth: 1)
                    )
                    .animation(
                        AnimationSettings.easeOut(ContainerConstants.Animation.emojiPickerDuration),
                        value: isEmpty
                    )
                    .background(isIconPickerHovering ? theme.mutedBackground.opacity(0.8)
                        : theme.mutedBackground)
                    .cornerRadius(ContainerConstants.UI.cornerRadius)

                if isEmpty {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                } else {
                    SpaceIconView(symbol: iconSymbol, colorHex: iconColorHex, emoji: emoji, size: 14)
                }
            }
        }
        .popover(isPresented: $isIconPickerOpen, arrowEdge: .bottom) {
            SpaceIconPicker(
                initialSymbol: iconSymbol,
                initialColorHex: iconColorHex,
                onSelect: apply
            )
        }
        .frame(width: ContainerConstants.UI.emojiButtonSize, height: ContainerConstants.UI.emojiButtonSize)
        .cornerRadius(ContainerConstants.UI.cornerRadius)
        .buttonStyle(InteractiveButtonStyle(cornerRadius: ContainerConstants.UI.cornerRadius, hoverOpacity: 0))
        .accessibilityLabel(Text("Choose Space Icon"))
        .onHover { isIconPickerHovering = $0 }
        .animation(AnimationSettings.easeOut(0.1), value: isIconPickerHovering)
    }

    /// An emoji clears any chosen symbol; a symbol wins over the stored emoji.
    private func apply(_ selection: SpaceIconSelection) {
        switch selection {
        case let .emoji(value):
            emoji = value
            iconSymbol = nil
            iconColorHex = nil
            isIconPickerOpen = false
        case let .symbol(name, colorHex):
            iconSymbol = name
            iconColorHex = colorHex
            isIconPickerOpen = false
        case let .color(colorHex):
            iconColorHex = colorHex
        }
    }

    private var nameTextField: some View {
        OraInput(
            text: $name,
            placeholder: "eg. work, streaming, finance...",
            onSubmit: onSubmit
        )
        .focused($isNameFocused)
    }
}
