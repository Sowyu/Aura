import SwiftUI

/// Sidebar row for a tab folder. Mirrors `TabItem`'s geometry so folders and tabs
/// line up: 8pt padding, 10pt corner radius, flat hover background.
struct FolderItem: View {
    let folder: Folder
    let isDropTarget: Bool
    let onToggle: () -> Void
    let onNewTab: () -> Void
    let onCloseTabs: () -> Void
    let onDelete: (_ closeTabs: Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme
    @Environment(TabManager.self) private var tabManager

    @State private var isHovering = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    private var isRenaming: Bool { tabManager.renamingFolderID == folder.id }
    private var tabCount: Int { folder.sortedTabs.count }

    var body: some View {
        // The folder glyph takes the favicon column and the chevron the close-button
        // column, so a folder's title starts where a tab's does.
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundColor(theme.foreground)
                .frame(width: 16, height: 16)
            title
            Spacer(minLength: 4)
            if folder.isCollapsed, tabCount > 0, !isRenaming {
                Text("\(tabCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.foreground.opacity(0.6))
            }
            Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.foreground.opacity(0.6))
                .frame(width: 20, height: 20)
        }
        .padding(8)
        .background(backgroundColor, in: .rect(cornerRadius: AuraRadius.row))
        .overlay(dropOutline)
        // No container stripe: a folder holds tabs from any container, so it belongs to none.
        .contentShape(ConditionallyConcentricRectangle(cornerRadius: AuraRadius.row))
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { if !isRenaming { onToggle() } }
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(folder.name))
        .accessibilityValue(Text(folder.isCollapsed ? "Collapsed" : "Expanded"))
        .accessibilityAddTraits(.isButton)
        .auraContextMenu { contextMenuItems }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            if renaming {
                draftName = folder.name
                nameFieldFocused = true
            }
        }
        .animation(AnimationSettings.easeOut(0.12), value: isHovering)
    }

    @ViewBuilder
    private var title: some View {
        if isRenaming {
            TextField("Folder Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.foreground)
                .focused($nameFieldFocused)
                .onSubmit(commitRename)
                .onExitCommand { tabManager.renamingFolderID = nil }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused { commitRename() }
                }
        } else {
            Text(folder.name)
                .font(.system(size: 13))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var dropOutline: some View {
        if isDropTarget {
            ConditionallyConcentricRectangle(cornerRadius: AuraRadius.row)
                .stroke(theme.invertedSolidWindowBackgroundColor.opacity(0.35), lineWidth: 1)
        }
    }

    private var backgroundColor: Color {
        if isDropTarget {
            return theme.activeTabBackground.opacity(0.3)
        }
        if isHovering || isRenaming {
            return theme.activeTabBackground.opacity(colorScheme == .dark ? 0.3 : 0.1)
        }
        return .clear
    }

    private var contextMenuItems: [AuraMenuItem] {
        [
            .item("Rename", icon: "pencil") { beginRename() },
            .item("New Tab in Folder", icon: "plus", action: onNewTab),
            .separator,
            .item("Close All Tabs in Folder", icon: "xmark", isDisabled: tabCount == 0, action: onCloseTabs),
            .item("Delete Folder", icon: "folder.badge.minus") { onDelete(false) },
            .item("Delete Folder and Tabs", icon: "trash", isDestructive: true) { onDelete(true) }
        ]
    }

    private func beginRename() {
        draftName = folder.name
        tabManager.renamingFolderID = folder.id
    }

    private func commitRename() {
        guard isRenaming else { return }
        tabManager.rename(folder: folder, to: draftName)
        tabManager.renamingFolderID = nil
    }
}
