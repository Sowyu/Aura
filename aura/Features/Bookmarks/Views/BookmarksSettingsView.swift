import SwiftUI

/// The bookmark manager, rendered as a settings section (⌥⌘B opens the section directly).
///
/// A section rather than a window of its own: settings already render inside a tab, the
/// card layout is the one every other list in Aura uses, and a second window would need
/// its own environment plumbing for a view that is a list with a context menu.
struct BookmarksSettingsView: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(DialogManager.self) private var dialogManager
    @EnvironmentObject private var privacyMode: PrivacyMode
    @Environment(\.theme) private var theme

    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var opener: BookmarkOpener {
        BookmarkOpener(
            tabManager: tabManager,
            historyManager: historyManager,
            downloadManager: downloadManager,
            store: store,
            isPrivate: privacyMode.isPrivate
        )
    }

    /// Searching flattens the folders: with three rows left, a card per folder is more
    /// chrome than content.
    private var searchResults: [Bookmark] {
        guard !trimmedQuery.isEmpty else { return [] }
        return store.search(trimmedQuery)
    }

    var body: some View {
        SettingsSection {
            SettingsCard(header: "Bookmarks bar", description: barDescription) {
                toolbar
                if trimmedQuery.isEmpty {
                    list(store.rootBookmarks, emptyMessage: "Nothing saved yet. Press \u{2318}D on any page.")
                } else {
                    list(searchResults, emptyMessage: "No bookmarks match that")
                }
            }

            if trimmedQuery.isEmpty {
                ForEach(store.folders) { folder in
                    SettingsCard(header: folder.name, description: folderDescription(folder)) {
                        HStack {
                            Spacer()
                            folderActions(folder)
                        }
                        list(store.bookmarks(in: folder), emptyMessage: "This folder is empty")
                    }
                }
            }

            BookmarkPortabilityCard()
        }
    }

    private var barDescription: String {
        SettingsStore.shared.showBookmarksBar
            ? "Shown under the toolbar. Press \u{21E7}\u{2318}B to hide it."
            : "Hidden. Press \u{21E7}\u{2318}B to show it under the toolbar."
    }

    private func folderDescription(_ folder: BookmarkFolder) -> String? {
        guard folder.isReadingList else { return nil }
        let unread = folder.bookmarks.filter(\.isUnread).count
        return unread == 0 ? "Everything here has been read." : "\(unread) unread."
    }

    // MARK: - Rows

    private var toolbar: some View {
        HStack(spacing: 8) {
            OraInput(
                text: $query,
                placeholder: "Search bookmarks",
                size: .sm,
                leadingIcon: "magnifyingglass"
            )
            OraButton(label: "New Folder", variant: .secondary, size: .sm, leadingIcon: "folder.badge.plus") {
                dialogManager.show { id in
                    BookmarkFolderDialog(folder: nil, store: store) { dialogManager.dismiss(id: id) }
                }
            }
        }
    }

    private func folderActions(_ folder: BookmarkFolder) -> some View {
        HStack(spacing: 6) {
            OraButton(label: "Rename", variant: .ghost, size: .sm) {
                dialogManager.show { id in
                    BookmarkFolderDialog(folder: folder, store: store) { dialogManager.dismiss(id: id) }
                }
            }
            OraButton(label: "Delete", variant: .ghost, size: .sm) { confirmDelete(folder) }
        }
    }

    @ViewBuilder
    private func list(_ bookmarks: [Bookmark], emptyMessage: String) -> some View {
        if bookmarks.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(bookmarks) { bookmark in
                    BookmarkManagerRow(
                        bookmark: bookmark,
                        onOpen: { opener.open(bookmark, inNewTab: false) },
                        onOpenInNewTab: { opener.open(bookmark, inNewTab: true) },
                        menu: {
                            BookmarkRowMenu.items(
                                for: bookmark,
                                store: store,
                                open: { opener.open(bookmark, inNewTab: $0) },
                                edit: { presentEdit(bookmark) }
                            )
                        }
                    )
                }
            }
        }
    }

    private func presentEdit(_ bookmark: Bookmark) {
        dialogManager.show { id in
            BookmarkEditDialog(bookmark: bookmark, store: store) { dialogManager.dismiss(id: id) }
        }
    }

    private func confirmDelete(_ folder: BookmarkFolder) {
        let count = folder.bookmarks.count
        dialogManager.confirm(
            title: "Delete \u{201C}\(folder.name)\u{201D}?",
            message: count == 0
                ? "The folder is empty."
                : "\(count) bookmark\(count == 1 ? "" : "s") inside it will be deleted too.",
            confirmLabel: "Delete",
            variant: .destructive,
            onConfirm: { store.delete(folder) }
        )
    }
}

/// One saved page in the manager. Shaped like `HistoryPanelRow`: hover reveals the
/// actions in place, nothing moves, and the right-click menu is Aura's own.
private struct BookmarkManagerRow: View {
    let bookmark: Bookmark
    let onOpen: () -> Void
    let onOpenInNewTab: () -> Void
    let menu: () -> [AuraMenuItem]

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            SiteFaviconView(host: bookmark.url?.host ?? "", size: 16, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.displayTitle)
                    // Unread reading-list items are the only bold rows in the manager.
                    .font(.system(size: 12, weight: bookmark.isUnread ? .semibold : .medium))
                    .foregroundColor(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(bookmark.urlString)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button(action: onOpenInNewTab) {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
            .help("Open in New Tab")
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            ConditionallyConcentricRectangle(cornerRadius: AuraRadius.row)
                .fill(isHovered ? theme.mutedBackground.opacity(0.5) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(AnimationSettings.easeOut(0.1)) { isHovered = hovering }
        }
        .onTapGesture(perform: onOpen)
        .auraContextMenu(menu)
    }
}
