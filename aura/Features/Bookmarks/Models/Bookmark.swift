import Foundation
import SwiftData

/// A saved page.
///
/// The reading list is not a second entity: an article put aside is a bookmark with
/// `isUnread` set, filed in the folder `BookmarkFolder.isReadingList` marks. Two tables
/// would have meant two managers, two migrations and two answers to "is this page
/// saved?", and the only thing that actually differs is the weight the row renders at.
@Model
final class Bookmark {
    @Attribute(.unique) var id: UUID
    var title: String
    /// Stored as text rather than as `URL` so a saved address that no longer parses is
    /// still visible and editable instead of failing the fetch that reads it.
    var urlString: String
    /// Icon address copied off the tab at save time. `FaviconService` fetches by host,
    /// so this is a hint, not the bytes.
    var faviconURL: URL?
    var createdAt: Date
    /// Position among siblings: root items among root items, folder items within their
    /// folder. Ties fall back to `createdAt`, so a store written before ordering existed
    /// still lists in a stable order.
    var order: Int
    var isUnread: Bool

    @Relationship(inverse: \BookmarkFolder.bookmarks) var folder: BookmarkFolder?

    init(
        id: UUID = UUID(),
        title: String,
        urlString: String,
        faviconURL: URL? = nil,
        createdAt: Date = Date(),
        order: Int = 0,
        isUnread: Bool = false,
        folder: BookmarkFolder? = nil
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.faviconURL = faviconURL
        self.createdAt = createdAt
        self.order = order
        self.isUnread = isUnread
        self.folder = folder
    }

    /// Nil when the stored text stopped parsing, which is what an edit can leave behind.
    /// Callers open nothing rather than opening a search for the broken address.
    var url: URL? {
        URL(string: urlString)
    }

    /// What the row shows when the page never reported a title.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return url?.host ?? urlString
    }
}

/// One level of grouping, and the only level there is.
///
/// There is deliberately no parent relationship: Firefox's flat-with-folders model is
/// what the bar and the sidebar already look like, and a folder that cannot hold a
/// folder makes the depth limit a fact of the type rather than a check every writer has
/// to remember.
@Model
final class BookmarkFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var order: Int
    /// The one folder "Add to Reading List" writes into. Marked rather than matched by
    /// name so renaming it does not strand the articles already in it.
    var isReadingList: Bool

    /// Deleting a folder takes its bookmarks with it, the way every browser's bookmark
    /// manager does. The row asks first.
    @Relationship(deleteRule: .cascade) var bookmarks: [Bookmark] = []

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        order: Int = 0,
        isReadingList: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.order = order
        self.isReadingList = isReadingList
    }
}
