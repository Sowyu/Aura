import AppKit
import SwiftUI

struct ShortcutsSettingsView: View {
    @StateObject private var shortcutManager = CustomKeyboardShortcutManager.shared
    @State private var editingShortcut: KeyboardShortcutDefinition?

    private var sections: [(category: String, items: [KeyboardShortcutDefinition])] {
        return KeyboardShortcuts.itemsByCategory
    }

    /// One card per category, like every other settings page. The `List` this replaces
    /// drew its own inset-grouped rows flush against the page header, so this was the
    /// only section whose content did not line up with the title above it.
    var body: some View {
        SettingsSection {
            ForEach(sections, id: \.category) { section in
                SettingsCard(header: section.category) {
                    ForEach(section.items) { item in
                        ShortcutRowView(
                            item: item,
                            isOverriden: shortcutManager.hasCustomShortcut(for: item),
                            isEditing: editingShortcut == item,
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
                }
            }
        }
    }

    private func handleAction(for item: KeyboardShortcutDefinition, action: ShortcutRowView.Action) {
        switch action {
        case .resetTapped:
            shortcutManager.removeCustomShortcut(for: item)
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
            cancelEditing()
        }
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

    let item: KeyboardShortcutDefinition
    let isOverriden: Bool
    let isEditing: Bool
    let handler: Action.Handler

    var body: some View {
        HStack(spacing: 16) {
            Text(item.name)
                .font(.system(size: 14))
                .foregroundColor(.primary)

            Spacer()

            if isOverriden {
                Button(action: { handler(.resetTapped) }) {
                    Text("Reset to Default")
                }
            }

            Button(action: { handler(.editTapped) }) {
                Text(item.display)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isEditing ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isEditing ?
                                Color.accentColor.opacity(0.1) :
                                Color(NSColor.controlBackgroundColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        isEditing ? Color.accentColor : Color(NSColor.separatorColor),
                                        lineWidth: isEditing ? 1.5 : 0.5
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
