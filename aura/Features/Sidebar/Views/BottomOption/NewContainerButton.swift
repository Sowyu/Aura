import AppKit
import SwiftUI

struct NewContainerButton: View {
    @Environment(\.theme) private var theme
    @Environment(DialogManager.self) private var dialogManager
    @Environment(TabManager.self) private var tabManager

    var body: some View {
        Button(action: {
            dialogManager.show { id in
                NewContainerDialog(dismiss: { dialogManager.dismiss(id: id) })
                    .environment(tabManager)
            }
        }) {
            HStack {
                Image(systemName: "plus")
                    .frame(width: 12, height: 12)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button, tint: theme.invertedSolidWindowBackgroundColor))
        .help("New Space")
        .accessibilityLabel(Text("New Space"))
    }
}

/// Shared with the sidebar's space header, which offers the same "New Space…" row.
struct NewContainerDialog: View {
    let dismiss: () -> Void

    @State private var name = ""
    @State private var emoji = ""
    @State private var iconSymbol: String? = ContainerConstants.defaultIconSymbol
    @State private var iconColorHex: String?
    @State private var isIconPickerOpen = false

    @Environment(\.theme) private var theme
    @Environment(TabManager.self) private var tabManager

    var body: some View {
        // Outer frame
        VStack(alignment: .leading, spacing: 0) {
            // Inner content
            VStack(alignment: .leading, spacing: 16) {
                // Icon
                AuraIcons(icon: .spaceCards, size: .custom(42), color: theme.mutedForeground)

                // Title
                Text("Create a new Space")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(theme.foreground)

                // Form section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose a name and icon")
                        .font(.system(size: 13))
                        .foregroundColor(theme.mutedForeground)

                    ContainerForm(
                        name: $name,
                        emoji: $emoji,
                        iconSymbol: $iconSymbol,
                        iconColorHex: $iconColorHex,
                        isIconPickerOpen: $isIconPickerOpen,
                        onSubmit: createContainer
                    )

                    // Info text
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                        Text("Each space has its own history, passwords and settings.")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(theme.mutedForeground)
                }

                Spacer()

                // Buttons
                HStack {
                    AuraButton(label: "Cancel", variant: .secondary, keyboardShortcut: "esc", action: dismiss)
                    Spacer()
                    AuraButton(
                        label: "Save",
                        isDisabled: name.isEmpty,
                        keyboardShortcut: "return",
                        action: createContainer
                    )
                }
            }
            .frame(
                width: ContainerConstants.UI.newContainerDialogWidth,
                height: ContainerConstants.UI.newContainerDialogHeight
            )
            .padding(12)
            .background(theme.popoverMutedBackground)
            .cornerRadius(AuraRadius.row)
            .overlay {
                ConditionallyConcentricRectangle(cornerRadius: AuraRadius.row)
                    .stroke(theme.border, lineWidth: 0.5)
            }
        }
        .padding(3)
        .background(theme.popoverBackground)
        .cornerRadius(AuraRadius.pane)
        .auraFloatingShadow()
    }

    private func createContainer() {
        guard !name.isEmpty else { return }
        let finalEmoji = emoji.isEmpty ? ContainerConstants.defaultEmoji : emoji
        tabManager.createContainer(
            name: name,
            emoji: finalEmoji,
            iconSymbol: iconSymbol,
            iconColorHex: iconColorHex
        )
        dismiss()
    }
}
