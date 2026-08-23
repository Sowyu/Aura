import Foundation
import SwiftData

/// Every bookmark and folder, on the store the window was handed.
///
/// One store per window, like `HistoryManager`, and for the same reason: a window's
/// views want a manager in the environment, not a `@Query` that re-runs the whole
/// chrome. Unlike history, the context this holds is always the on-disk one, even in a
/// private window: a page saved on purpose is not browsing data, and losing it when the
/// window closes is not privacy, it is a bug. `OraRoot` is where that choice is made.
///
/// Cached lists rather than fetch-per-render: the bar draws on every chrome pass, and a
/// fetch there showed up in the toolbar's frame time. Writers refresh the cache and post
/// `.bookmarksChanged`, which is how a second window learns about the first one's ⌘D.
@Observable
@MainActor
final class BookmarkStore {
    /// Ceiling on one reload. A bookmark bar past this is not a bar any more, and the
    /// fetch is on the chrome's path.
    /// ponytail: paged fetches if anyone ever reports hitting it.
    static let fetchLimit = 500
    /// Ceiling on a launcher or manager search.
    static let searchLimit = 50
    static let readingListName = "Reading List"

    let modelContext: ModelContext

    /// Root-level items, in bar order. Folders sort before loose bookmarks so the bar's
    /// left edge stays stable as pages come and go.
    private(set) var folders: [BookmarkFolder] = []
    private(set) var rootBookmarks: [Bookmark] = []

    /// Written once in `init` and read once in `deinit`, which is nonisolated, hence the
    /// unchecked marking rather than main-actor isolation.
    @ObservationIgnored private nonisolated(unsafe) var changeObserver: NSObjectProtocol?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        reload()
        changeObserver = NotificationCenter.default.addObserver(
            forName: .bookmarksChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The window that made the change refreshed its own cache already.
                if let sender = note.object as AnyObject?, sender === self {
                    return
                }
                self.reload()
            }
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    // MARK: - Reading

    func reload() {
        var descriptor = FetchDescriptor<Bookmark>(
            sortBy: [SortDescriptor(\.order), SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = Self.fetchLimit

        var folderDescriptor = FetchDescriptor<BookmarkFolder>(
            sortBy: [SortDescriptor(\.order), SortDescriptor(\.createdAt)]
        )
        folderDescriptor.fetchLimit = Self.fetchLimit

        do {
            let all = try modelContext.fetch(descriptor)
            // Partitioned here rather than in a predicate: a nil-relationship test is the
            // one shape `#Predicate` translates least reliably, and the fetch is bounded
            // anyway.
            rootBookmarks = all.filter { $0.folder == nil }
            folders = try modelContext.fetch(folderDescriptor)
        } catch {
            AuraLog.category("Bookmarks").error(
                "Reading the bookmark store failed: \(error.localizedDescription, privacy: .public)"
            )
            rootBookmarks = []
            folders = []
        }
    }

    /// Items inside one folder, in row order. Reads the relationship rather than
    /// fetching: the folder is already faulted in by `reload`.
    func bookmarks(in folder: BookmarkFolder) -> [Bookmark] {
        folder.bookmarks.sorted {
            ($0.order, $0.createdAt) < ($1.order, $1.createdAt)
        }
    }

    /// The reading list, newest first, unread before read. Nil folder means nothing has
    /// been put aside yet.
    var readingList: [Bookmark] {
        guard let folder = folders.first(where: \.isReadingList) else { return [] }
        return folder.bookmarks.sorted {
            if $0.isUnread != $1.isUnread {
                return $0.isUnread
            }
            return $0.createdAt > $1.createdAt
        }
    }

    /// The saved row for an address, if there is one. Exact match on the stored text:
    /// two addresses that differ by a trailing slash are two pages as far as a browser
    /// is concerned, and guessing otherwise loses the one the user actually saved.
    func bookmark(for url: URL) -> Bookmark? {
        rows(for: url).first
    }

    /// Every saved row for one address. Small by construction (a page is saved once per
    /// list at most), so the folder scoping below filters in memory.
    private func rows(for url: URL) -> [Bookmark] {
        let target = url.absoluteString
        var descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.urlString == target },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 16
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func isBookmarked(_ url: URL) -> Bool {
        bookmark(for: url) != nil
    }

    func search(_ text: String, limit: Int = BookmarkStore.searchLimit) -> [Bookmark] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate {
                $0.title.localizedStandardContains(trimmed)
                    || $0.urlString.localizedStandardContains(trimmed)
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            AuraLog.category("Bookmarks").error(
                "Searching bookmarks failed: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    // MARK: - Writing

    /// Saves a page, or returns the row that already holds it in the same list.
    ///
    /// ⌘D on a page that is already on the bar refreshes its title and icon instead of
    /// adding a second row: the alternative is a bar that grows a duplicate every time
    /// someone presses the shortcut twice. The scope is the target list, not the whole
    /// store, so a page can be both bookmarked and waiting in the reading list.
    @discardableResult
    func add(
        title: String,
        url: URL,
        faviconURL: URL? = nil,
        folder: BookmarkFolder? = nil,
        isUnread: Bool = false
    ) -> Bookmark? {
        // aura:// pages are chrome. Guarded here rather than at each caller so no
        // affordance can file the settings tab under Bookmarks.
        guard !url.isOraInternal else { return nil }

        if let existing = rows(for: url).first(where: { $0.folder === folder }) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                existing.title = trimmed
            }
            if let faviconURL {
                existing.faviconURL = faviconURL
            }
            existing.isUnread = isUnread || existing.isUnread
            commit()
            return existing
        }

        let bookmark = Bookmark(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            urlString: url.absoluteString,
            faviconURL: faviconURL,
            order: nextOrder(in: folder),
            isUnread: isUnread,
            folder: folder
        )
        modelContext.insert(bookmark)
        commit()
        return bookmark
    }

    /// Puts a page aside to read. Same entity, filed in the reading list and unread.
    @discardableResult
    func addToReadingList(title: String, url: URL, faviconURL: URL? = nil) -> Bookmark? {
        guard !url.isOraInternal else { return nil }
        return add(
            title: title,
            url: url,
            faviconURL: faviconURL,
            folder: readingListFolder(),
            isUnread: true
        )
    }

    /// The reading list folder, created on first use. Sorted ahead of the folders the
    /// user made: it is the one nobody chose to have.
    @discardableResult
    func readingListFolder() -> BookmarkFolder {
        if let existing = folders.first(where: \.isReadingList) {
            return existing
        }
        let folder = BookmarkFolder(name: Self.readingListName, order: -1, isReadingList: true)
        modelContext.insert(folder)
        commit()
        return folder
    }

    @discardableResult
    func createFolder(named name: String) -> BookmarkFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = BookmarkFolder(
            name: trimmed.isEmpty ? "New Folder" : trimmed,
            order: (folders.map(\.order).max() ?? 0) + 1
        )
        modelContext.insert(folder)
        commit()
        return folder
    }

    /// Applies an edit from the manager or the row's Edit action. An empty address is
    /// ignored: it would leave a row that opens nothing.
    func update(_ bookmark: Bookmark, title: String, urlString: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmark.title = trimmedTitle
        if !trimmedURL.isEmpty {
            bookmark.urlString = trimmedURL
        }
        commit()
    }

    func rename(_ folder: BookmarkFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
        commit()
    }

    /// Moves a bookmark between the bar and a folder. `nil` is the bar.
    func move(_ bookmark: Bookmark, to folder: BookmarkFolder?) {
        guard bookmark.folder !== folder else { return }
        bookmark.folder = folder
        bookmark.order = nextOrder(in: folder)
        commit()
    }

    func setUnread(_ bookmark: Bookmark, _ isUnread: Bool) {
        guard bookmark.isUnread != isUnread else { return }
        bookmark.isUnread = isUnread
        commit()
    }

    /// Opening an item is what marks it read, so this is called from the open path and
    /// returns early on everything already read: the common case must not write.
    func markRead(_ bookmark: Bookmark) {
        setUnread(bookmark, false)
    }

    func delete(_ bookmark: Bookmark) {
        modelContext.delete(bookmark)
        commit()
    }

    /// Takes the folder's bookmarks with it, per the cascade rule on the relationship.
    func delete(_ folder: BookmarkFolder) {
        modelContext.delete(folder)
        commit()
    }

    // MARK: - Internals

    /// Last position in the target list plus one, so a new row lands at the end.
    private func nextOrder(in folder: BookmarkFolder?) -> Int {
        let siblings = folder.map { $0.bookmarks.map(\.order) } ?? rootBookmarks.map(\.order)
        return (siblings.max() ?? 0) + 1
    }

    /// One save, one refresh, one announcement. Every writer above ends here so no path
    /// can leave the cache and the store disagreeing.
    private func commit() {
        saveOrLog(modelContext)
        reload()
        NotificationCenter.default.post(name: .bookmarksChanged, object: self)
    }
}

/// Opening a saved page, from the bar, a folder menu or the manager.
///
/// Everything goes through `TabManager` and `Tab.loadURL`, which is the same path a
/// clicked link takes: the site-to-space rules in `TabBrowserPageDelegate` and every
/// other navigation policy then see a bookmark exactly as they see a link. There is
/// deliberately no direct call into WebKit here.
@MainActor
struct BookmarkOpener {
    let tabManager: TabManager
    let historyManager: HistoryManager
    let downloadManager: DownloadManager
    let store: BookmarkStore
    let isPrivate: Bool

    /// Reading marks itself on open, which is the whole interaction the reading list has.
    func open(_ bookmark: Bookmark, inNewTab: Bool = false) {
        guard let url = bookmark.url else { return }
        store.markRead(bookmark)
        open(url, inNewTab: inNewTab)
    }

    func open(_ url: URL, inNewTab: Bool) {
        if inNewTab || tabManager.activeTab == nil {
            tabManager.openTab(
                url: url,
                historyManager: historyManager,
                downloadManager: downloadManager,
                isPrivate: isPrivate
            )
        } else {
            tabManager.activeTab?.loadURL(url.absoluteString)
        }
    }
}
