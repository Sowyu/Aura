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
    @EnvironmentObject var tabManager: TabManager

    @State private var isHovering = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    private var isRenaming: Bool { tabManager.renamingFolderID == folder.id }
    private var tabCount: Int { folder.sortedTabs.count }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.foreground.opacity(0.6))
                .frame(width: 10)
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
        }
        .padding(8)
        .background(backgroundColor, in: .rect(cornerRadius: 10))
        .overlay(dropOutline)
        .contentShape(ConditionallyConcentricRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { if !isRenaming { onToggle() } }
        .onHover { isHovering = $0 }
        .contextMenu { contextMenuItems }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            if renaming {
                draftName = folder.name
                nameFieldFocused = true
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
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
            ConditionallyConcentricRectangle(cornerRadius: 10)
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

    @ViewBuilder
    private var contextMenuItems: some View {
        Button { beginRename() } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(action: onNewTab) {
            Label("New Tab in Folder", systemImage: "plus")
        }
        Divider()
        Button(action: onCloseTabs) {
            Label("Close All Tabs in Folder", systemImage: "xmark")
        }
        .disabled(tabCount == 0)
        Button { onDelete(false) } label: {
            Label("Delete Folder", systemImage: "folder.badge.minus")
        }
        Button(role: .destructive) { onDelete(true) } label: {
            Label("Delete Folder and Tabs", systemImage: "trash")
        }
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
