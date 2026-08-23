import AppKit
import SwiftUI

struct ShortcutsSettingsView: View {
    @StateObject private var shortcutManager = CustomKeyboardShortcutManager.shared
    @State private var editingShortcut: KeyboardShortcutDefinition?

    private let extensionManager = ExtensionManager.shared

    private var sections: [(category: String, items: [KeyboardShortcutDefinition])] {
        return KeyboardShortcuts.itemsByCategory
    }

    /// Commands the loaded extensions declare, bindable like any built-in shortcut.
    /// Empty until an extension with commands has loaded, so the card only appears for
    /// someone who has one.
    private var extensionShortcuts: [ExtensionCommandShortcut] {
        extensionManager.commandShortcuts()
    }

    /// One card per category, like every other settings page. The `List` this replaces
    /// drew its own inset-grouped rows flush against the page header, so this was the
    /// only section whose content did not line up with the title above it.
    var body: some View {
        SettingsSection {
            ForEach(sections, id: \.category) { section in
                SettingsCard(header: section.category) {
                    ForEach(section.items) { item in
                        row(for: item)
                    }
                }
            }
            extensionsCard
        }
    }

    /// One card for every extension command, under the built-in categories: they come
    /// and go with what is installed, so they do not belong in the fixed list above.
    @ViewBuilder
    private var extensionsCard: some View {
        let shortcuts = extensionShortcuts
        if !shortcuts.isEmpty {
            SettingsCard(header: ExtensionCommandShortcut.category) {
                ForEach(shortcuts) { shortcut in
                    row(for: shortcut.definition, display: shortcut.display)
                }
            }
        }
    }

    private func row(for item: KeyboardShortcutDefinition, display: String? = nil) -> some View {
        ShortcutRowView(
            item: item,
            isOverriden: shortcutManager.hasCustomShortcut(for: item),
            isEditing: editingShortcut == item,
            displayText: display,
            handler: { action in
                handleAction(for: item, action: action)
            }
        )
        .overlay {
            if editingShortcut == item {
                KeyCaptureView(onKeyDown: { event in
                    handleKeyCapture(event)
                })
                .allowsHitTesting(false)
            }
        }
    }

    private func handleAction(for item: KeyboardShortcutDefinition, action: ShortcutRowView.Action) {
        switch action {
        case .resetTapped:
            shortcutManager.removeCustomShortcut(for: item)
            applyIfExtensionCommand(item)
            cancelEditing()
        case .editTapped:
            if editingShortcut == item {
                cancelEditing()
            } else {
                editingShortcut = item
            }
        }
    }

    private func handleKeyCapture(_ event: NSEvent) {
        guard let editingShortcut else { return }
        if KeyChord(fromEvent: event) != nil {
            shortcutManager.setCustomShortcut(for: editingShortcut, event: event)
            applyIfExtensionCommand(editingShortcut)
            cancelEditing()
        }
    }

    /// A rebound extension command has to reach WebKit, which is what actually matches
    /// the key press.
    private func applyIfExtensionCommand(_ item: KeyboardShortcutDefinition) {
        guard item.id.hasPrefix(ExtensionCommandShortcut.idPrefix) else { return }
        extensionManager.applyCommandShortcuts()
    }

    private func cancelEditing() {
        editingShortcut = nil
    }
}

struct ShortcutRowView: View {
    enum Action {
        case resetTapped
        case editTapped

        typealias Handler = (Self) -> Void
    }

    @Environment(\.theme) private var theme

    let item: KeyboardShortcutDefinition
    let isOverriden: Bool
    let isEditing: Bool
    /// What the chip shows, when it is not simply the current chord. An extension
    /// command with no shortcut at all has nothing to display, and "Not set" is what
    /// the row says instead of a key nobody can press.
    var displayText: String?
    let handler: Action.Handler

    var body: some View {
        HStack(spacing: 16) {
            Text(item.name)
                .font(.system(size: 13))
                .foregroundStyle(theme.foreground)

            Spacer()

            if isOverriden {
                Button(action: { handler(.resetTapped) }) {
                    Text("Reset to Default")
                }
            }

            Button(action: { handler(.editTapped) }) {
                Text(displayText ?? item.display)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isEditing ? theme.foreground : theme.mutedForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
                            .fill(isEditing ? theme.accent.opacity(0.12) : theme.mutedBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
                                    .stroke(
                                        isEditing ? theme.accent : theme.border,
                                        lineWidth: 1
                                    )
                            )
                    )
            }
            .buttonStyle(.plain)
            // The chip already switches to an accent fill and a heavier stroke while it
            // waits for a chord; growing it as well broke the no-scale rule.
            .animation(AnimationSettings.easeOut(0.1), value: isEditing)
        }
        .padding(.vertical, 4)
    }
}
