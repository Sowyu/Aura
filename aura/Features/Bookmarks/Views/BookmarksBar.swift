import AppKit
import SwiftUI

/// The row of saved pages under the toolbar.
///
/// Placed by `BrowserView` rather than inside `TopToolbar`: the toolbar row balances its
/// two button groups against each other to centre the address field, and a second row of
/// content inside that measurement would fight it. The geometry still comes from the
/// toolbar. `TopToolbar.verticalSlack` is the gap the row already leaves under the
/// address pill, so the bar only adds the same slack below itself and the content pane
/// keeps the inset it had before the bar existed.
struct BookmarksBar: View {
    /// Height of one item. Small enough that the bar costs less than the toolbar row.
    static let itemHeight: CGFloat = 22
    static let rowHeight: CGFloat = itemHeight + TopToolbar.verticalSlack

    private static let edgeInset: CGFloat = 12
    private static let itemSpacing: CGFloat = 2
    /// Long titles truncate rather than pushing everything else off the bar.
    private static let maxTitleWidth: CGFloat = 140
    private static let iconSize: CGFloat = 14

    @Environment(BookmarkStore.self) private var store
    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(DialogManager.self) private var dialogManager
    @EnvironmentObject private var privacyMode: PrivacyMode
    @Environment(\.theme) private var theme

    @State private var isDropTargeted = false
    /// One anchor per open folder menu, keyed by folder id: the menu hangs off the
    /// button that was clicked, and each button needs its own view to hang from.
    @State private var folderAnchors: [UUID: NSView] = [:]

    private var opener: BookmarkOpener {
        BookmarkOpener(
            tabManager: tabManager,
            historyManager: historyManager,
            downloadManager: downloadManager,
            store: store,
            isPrivate: privacyMode.isPrivate
        )
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.itemSpacing) {
                ForEach(store.folders) { folder in
                    folderButton(folder)
                }
                ForEach(store.rootBookmarks) { bookmark in
                    bookmarkButton(bookmark)
                }
                if store.folders.isEmpty, store.rootBookmarks.isEmpty {
                    emptyHint
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.edgeInset)
            .frame(height: Self.itemHeight)
        }
        .frame(height: Self.rowHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(dropHighlight)
        .auraGlassChromeForeground()
        // Accepts the address field's drag, and any URL dragged in from another app.
        .dropDestination(for: URL.self) { urls, _ in
            saveDropped(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .auraBackgroundContextMenu { barMenuItems }
        .accessibilityLabel(Text("Bookmarks bar"))
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            Rectangle().fill(theme.mutedBackground.opacity(0.6))
        }
    }

    private var emptyHint: some View {
        Text("Drag the address bar's icon here to keep a page")
            .font(.system(size: 11))
            .foregroundStyle(theme.mutedForeground)
            .padding(.horizontal, 4)
    }

    // MARK: - Items

    private func bookmarkButton(_ bookmark: Bookmark) -> some View {
        Button {
            opener.open(bookmark, inNewTab: Self.wantsNewTab())
        } label: {
            HStack(spacing: 5) {
                SiteFaviconView(
                    host: bookmark.url?.host ?? "",
                    size: Self.iconSize,
                    cornerRadius: 3
                )
                Text(bookmark.displayTitle)
                    .font(.system(size: 11, weight: bookmark.isUnread ? .semibold : .regular))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 6)
            .frame(height: Self.itemHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button, tint: theme.foreground))
        .help(bookmark.urlString)
        .auraContextMenu { bookmarkMenuItems(bookmark) }
    }

    private func folderButton(_ folder: BookmarkFolder) -> some View {
        Button {
            folderAnchors[folder.id]?.presentAuraMenu(folderMenuItems(folder))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: folder.isReadingList ? "eyeglasses" : "folder")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: Self.iconSize, height: Self.iconSize)
                Text(folder.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 6)
            .frame(height: Self.itemHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button, tint: theme.foreground))
        .background(AuraMenuAnchorView { folderAnchors[folder.id] = $0 })
        .auraContextMenu { folderContextMenuItems(folder) }
    }

    // MARK: - Menus

    private func folderMenuItems(_ folder: BookmarkFolder) -> [AuraMenuItem] {
        let items = store.bookmarks(in: folder)
        guard !items.isEmpty else { return [.disabled("Empty folder")] }
        return items.map { bookmark in
            // The menu row has no place for a favicon and no weight of its own, so an
            // unread article says so with a filled dot where the icon goes.
            .item(
                bookmark.displayTitle,
                icon: bookmark.isUnread ? "circle.fill" : "globe"
            ) {
                opener.open(bookmark, inNewTab: Self.wantsNewTab())
            }
        }
    }

    private func bookmarkMenuItems(_ bookmark: Bookmark) -> [AuraMenuItem] {
        BookmarkRowMenu.items(
            for: bookmark,
            store: store,
            open: { opener.open(bookmark, inNewTab: $0) },
            edit: { presentEdit(bookmark) }
        )
    }

    private func folderContextMenuItems(_ folder: BookmarkFolder) -> [AuraMenuItem] {
        [
            .item("Open All", icon: "square.on.square") {
                for bookmark in store.bookmarks(in: folder) {
                    opener.open(bookmark, inNewTab: true)
                }
            },
            .separator,
            .item("Rename Folder…", icon: "pencil") { presentRename(folder) },
            .item("Delete Folder", icon: "trash", isDestructive: true) { confirmDelete(folder) }
        ]
    }

    private var barMenuItems: [AuraMenuItem] {
        [
            .item("Add Bookmark…", icon: "bookmark", shortcut: KeyboardShortcuts.Bookmarks.add) {
                NotificationCenter.default.post(name: .addBookmark, object: NSApp.keyWindow)
            },
            .item("New Folder…", icon: "folder.badge.plus") { presentNewFolder() },
            .separator,
            .item("Hide Bookmarks Bar", icon: "eye.slash", shortcut: KeyboardShortcuts.Bookmarks.toggleBar) {
                SettingsStore.shared.showBookmarksBar = false
            }
        ]
    }

    // MARK: - Actions

    /// ⌘-click and middle-click open in a new tab, the way a link does. Read from the
    /// current event rather than tracked: a SwiftUI button action has no gesture to carry
    /// the flags. `buttonNumber` is only meaningful on an "other" mouse event, hence the
    /// type check before it is read.
    static func wantsNewTab() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        if event.modifierFlags.contains(.command) {
            return true
        }
        return event.type == .otherMouseUp || event.type == .otherMouseDown
    }

    /// A URL dropped on the bar is saved at root. The title comes off the active tab when
    /// the drop is that tab's own address (the usual case: dragging out of the address
    /// field), and from the host otherwise, because a bare URL carries no title.
    private func saveDropped(_ urls: [URL]) -> Bool {
        var saved = false
        for url in urls {
            let matchesActiveTab = tabManager.activeTab?.url == url
            let title = matchesActiveTab ? (tabManager.activeTab?.title ?? "") : (url.host ?? url.absoluteString)
            let favicon = matchesActiveTab ? tabManager.activeTab?.favicon : nil
            if store.add(title: title, url: url, faviconURL: favicon) != nil {
                saved = true
            }
        }
        return saved
    }

    private func presentEdit(_ bookmark: Bookmark) {
        dialogManager.show { id in
            BookmarkEditDialog(bookmark: bookmark, store: store) { dialogManager.dismiss(id: id) }
        }
    }

    private func presentNewFolder() {
        dialogManager.show { id in
            BookmarkFolderDialog(folder: nil, store: store) { dialogManager.dismiss(id: id) }
        }
    }

    private func presentRename(_ folder: BookmarkFolder) {
        dialogManager.show { id in
            BookmarkFolderDialog(folder: folder, store: store) { dialogManager.dismiss(id: id) }
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

/// The rows a saved page offers wherever it is shown. One definition so the bar and the
/// manager cannot drift apart on what right-clicking a bookmark does.
enum BookmarkRowMenu {
    @MainActor
    static func items(
        for bookmark: Bookmark,
        store: BookmarkStore,
        open: @escaping (Bool) -> Void,
        edit: @escaping () -> Void
    ) -> [AuraMenuItem] {
        [
            .item("Open", icon: "arrow.turn.down.right") { open(false) },
            .item("Open in New Tab", icon: "plus.square.on.square") { open(true) },
            .separator,
            .item("Copy Link", icon: "link") { ClipboardUtils.copyToClipboard(bookmark.urlString) },
            .item("Edit…", icon: "pencil", action: edit),
            .item(
                bookmark.isUnread ? "Mark as Read" : "Mark as Unread",
                icon: bookmark.isUnread ? "envelope.open" : "envelope.badge"
            ) {
                store.setUnread(bookmark, !bookmark.isUnread)
            },
            .submenu("Move to", icon: "folder", items: moveItems(for: bookmark, store: store)),
            .separator,
            .item("Delete", icon: "trash", isDestructive: true) { store.delete(bookmark) }
        ]
    }

    @MainActor
    private static func moveItems(for bookmark: Bookmark, store: BookmarkStore) -> [AuraMenuItem] {
        var rows: [AuraMenuItem] = [
            .item(
                "Bookmarks Bar",
                icon: "bookmark",
                state: bookmark.folder == nil ? .radioOn : .none
            ) {
                store.move(bookmark, to: nil)
            }
        ]
        for folder in store.folders {
            rows.append(
                .item(
                    folder.name,
                    icon: folder.isReadingList ? "eyeglasses" : "folder",
                    state: bookmark.folder?.id == folder.id ? .radioOn : .none
                ) {
                    store.move(bookmark, to: folder)
                }
            )
        }
        return rows
    }
}
