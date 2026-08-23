import Foundation
import SwiftData

/// Which file the user picked, and therefore which parser reads it.
enum BookmarkImportFormat {
    /// Chrome, Firefox, Edge, Brave, Vivaldi and anything else that writes the
    /// `NETSCAPE-Bookmark-file-1` export.
    case netscapeHTML
    /// `Bookmarks.plist` out of `~/Library/Safari`.
    case safariPropertyList

    func parse(_ data: Data) -> [ImportedBookmark] {
        switch self {
        case .netscapeHTML: return NetscapeBookmarks.parse(data)
        case .safariPropertyList: return SafariBookmarks.parse(data)
        }
    }
}

/// Moving bookmarks between Aura's store and a file another browser wrote.
///
/// The parsers above know nothing about SwiftData and this knows nothing about parsing,
/// which is what lets every format be tested against a fixture without a model container.
@MainActor
enum BookmarkPortability {
    /// Ceiling on one import. A bookmarks file an order of magnitude past this is not a
    /// person's bookmarks, and the writes here are one transaction, so an unbounded file
    /// would be one unbounded transaction.
    /// ponytail: raise it if anyone reports a real export getting truncated.
    static let importLimit = 5000

    /// What was written, so the caller can say so without knowing how.
    struct ImportSummary: Equatable {
        var added: Int
        var skipped: Int
        var foldersCreated: Int

        var isEmpty: Bool {
            added == 0 && foldersCreated == 0
        }
    }

    // MARK: - Import

    /// Writes the parsed rows into the store, in one transaction.
    ///
    /// Goes through `modelContext` rather than `BookmarkStore.add` per row on purpose:
    /// `add` saves, re-fetches the whole store and posts a notification every time, so a
    /// two thousand row import would be two thousand transactions and a quadratic number
    /// of fetches. The store's invariants still hold, because this ends the way `add`
    /// does: one `saveOrLog`, one `reload`, one `.bookmarksChanged`.
    @discardableResult
    static func apply(_ items: [ImportedBookmark], to store: BookmarkStore) -> ImportSummary {
        let context = store.modelContext
        var existingURLs = Set(allBookmarks(in: store).map(\.urlString))
        var foldersByName: [String: BookmarkFolder] = [:]
        for folder in store.folders {
            foldersByName[folder.name.lowercased()] = folder
        }

        var rootOrder = store.rootBookmarks.map(\.order).max() ?? 0
        var folderOrders: [UUID: Int] = [:]
        var folderRank = store.folders.map(\.order).max() ?? 0
        var summary = ImportSummary(added: 0, skipped: 0, foldersCreated: 0)

        for item in items.prefix(importLimit) {
            guard let url = URL(string: item.urlString), !url.isOraInternal else {
                summary.skipped += 1
                continue
            }
            // Dedupe on the stored text, the same comparison `BookmarkStore.bookmark(for:)`
            // makes: two addresses that differ by a trailing slash are two pages, and
            // collapsing them would silently drop one the user actually saved.
            guard existingURLs.insert(url.absoluteString).inserted else {
                summary.skipped += 1
                continue
            }

            var folder: BookmarkFolder?
            if let name = item.folderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                if name.caseInsensitiveCompare(BookmarkStore.readingListName) == .orderedSame {
                    // Safari's reading list, and any folder someone named the same thing,
                    // belongs in the list Aura already has rather than beside it.
                    folder = store.readingListFolder()
                    foldersByName[name.lowercased()] = folder
                } else if let existing = foldersByName[name.lowercased()] {
                    folder = existing
                } else {
                    folderRank += 1
                    let created = BookmarkFolder(name: name, order: folderRank)
                    context.insert(created)
                    foldersByName[name.lowercased()] = created
                    folder = created
                    summary.foldersCreated += 1
                }
            }

            let order: Int
            if let folder {
                let next = (folderOrders[folder.id] ?? folder.bookmarks.map(\.order).max() ?? 0) + 1
                folderOrders[folder.id] = next
                order = next
            } else {
                rootOrder += 1
                order = rootOrder
            }

            context.insert(Bookmark(
                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                urlString: url.absoluteString,
                createdAt: item.addedAt ?? Date(),
                order: order,
                isUnread: folder?.isReadingList == true,
                folder: folder
            ))
            summary.added += 1
        }

        summary.skipped += max(0, items.count - importLimit)

        guard !summary.isEmpty else { return summary }
        saveOrLog(context)
        store.reload()
        NotificationCenter.default.post(name: .bookmarksChanged, object: store)
        return summary
    }

    // MARK: - Export

    /// Everything the store holds, in bar-then-folder order so the exported file reads
    /// top to bottom the way the bar does left to right.
    static func exportable(from store: BookmarkStore) -> [ImportedBookmark] {
        var rows = store.rootBookmarks.map { row($0) }
        for folder in store.folders {
            rows += store.bookmarks(in: folder).map { row($0, folderName: folder.name) }
        }
        return rows
    }

    private static func row(_ bookmark: Bookmark, folderName: String? = nil) -> ImportedBookmark {
        ImportedBookmark(
            title: bookmark.displayTitle,
            urlString: bookmark.urlString,
            folderName: folderName,
            addedAt: bookmark.createdAt
        )
    }

    private static func allBookmarks(in store: BookmarkStore) -> [Bookmark] {
        store.rootBookmarks + store.folders.flatMap { store.bookmarks(in: $0) }
    }
}
