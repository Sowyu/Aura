import AppKit
@testable import Aura
import Foundation
import SwiftData
import Testing

/// The bookmark store: what ⌘D writes, how folders hold rows, what "unread" means, and
/// that a store written before bookmarks existed opens through the plan.
@MainActor
struct BookmarkStoreTests {
    private func makeStore() throws -> BookmarkStore {
        let container = try ModelContainer(
            for: Bookmark.self, BookmarkFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return BookmarkStore(modelContext: ModelContext(container))
    }

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    // MARK: - Writing

    @Test func savingAPageKeepsItsTitleAndAddress() throws {
        let store = try makeStore()
        let saved = try store.add(title: "  Example  ", url: url("https://example.com/a"))

        #expect(saved?.title == "Example")
        #expect(saved?.urlString == "https://example.com/a")
        #expect(saved?.isUnread == false)
        #expect(saved?.folder == nil)
        #expect(store.rootBookmarks.count == 1)
    }

    @Test func savingTheSamePageTwiceRefreshesItInsteadOfDuplicatingIt() throws {
        let store = try makeStore()
        let target = try url("https://example.com/a")
        let first = store.add(title: "Old title", url: target)
        let second = try store.add(title: "New title", url: target, faviconURL: url("https://example.com/i.png"))

        #expect(first?.id == second?.id)
        #expect(store.rootBookmarks.count == 1)
        #expect(store.rootBookmarks.first?.title == "New title")
        #expect(store.rootBookmarks.first?.faviconURL?.absoluteString == "https://example.com/i.png")
    }

    /// The bar and a folder are separate lists, so the same page can sit on both. Only a
    /// second row in the *same* list is a duplicate.
    @Test func aPageCanBeOnTheBarAndInAFolderAtOnce() throws {
        let store = try makeStore()
        let target = try url("https://example.com/a")
        let folder = store.createFolder(named: "Work")

        let onBar = store.add(title: "Example", url: target)
        let inFolder = store.add(title: "Example", url: target, folder: folder)

        #expect(onBar?.id != inFolder?.id)
        #expect(store.rootBookmarks.count == 1)
        #expect(store.bookmarks(in: folder).count == 1)
    }

    @Test func internalPagesAreNotBookmarkable() throws {
        let store = try makeStore()
        #expect(store.add(title: "Settings", url: .oraSettings(section: nil)) == nil)
        #expect(store.add(title: "New Tab", url: .oraHome) == nil)
        #expect(store.addToReadingList(title: "New Tab", url: .oraHome) == nil)
        // Nothing was written, so no reading list folder was conjured up either.
        #expect(store.rootBookmarks.isEmpty)
        #expect(store.folders.isEmpty)
    }

    @Test func editingWritesTheNewTitleAndAddressButNeverAnEmptyOne() throws {
        let store = try makeStore()
        let saved = try #require(try store.add(title: "Example", url: url("https://example.com/a")))

        store.update(saved, title: "Renamed", urlString: "https://example.com/b")
        #expect(saved.title == "Renamed")
        #expect(saved.urlString == "https://example.com/b")

        store.update(saved, title: "Renamed", urlString: "   ")
        #expect(saved.urlString == "https://example.com/b")
    }

    @Test func aRowWithAnUnparseableAddressStillShowsSomething() throws {
        let store = try makeStore()
        let saved = try #require(try store.add(title: "", url: url("https://example.com/a")))
        // No title: the row falls back to the host rather than rendering blank.
        #expect(saved.displayTitle == "example.com")
    }

    // MARK: - Ordering

    @Test func newRowsLandAtTheEndOfTheirOwnList() throws {
        let store = try makeStore()
        let folder = store.createFolder(named: "Work")

        let first = try store.add(title: "One", url: url("https://one.example"))
        let second = try store.add(title: "Two", url: url("https://two.example"))
        let inFolder = try store.add(title: "Three", url: url("https://three.example"), folder: folder)

        #expect(try #require(second?.order) > #require(first?.order))
        #expect(store.rootBookmarks.map(\.title) == ["One", "Two"])
        // A folder counts its own positions, so the first row in it is not pushed to the
        // end of the bar's numbering.
        #expect(inFolder?.order == 1)
    }

    // MARK: - Folders

    @Test func foldersHoldBookmarksAndNothingElse() throws {
        let store = try makeStore()
        let work = store.createFolder(named: "Work")
        let saved = try #require(try store.add(title: "Example", url: url("https://example.com/a")))

        store.move(saved, to: work)
        #expect(store.rootBookmarks.isEmpty)
        #expect(store.bookmarks(in: work).map(\.id) == [saved.id])
        #expect(saved.folder?.id == work.id)

        // One level, and it is the type that says so: a folder's only relationship is to
        // bookmarks, so there is no call that could nest one inside another.
        #expect(store.folders.count == 1)

        store.move(saved, to: nil)
        #expect(store.bookmarks(in: work).isEmpty)
        #expect(store.rootBookmarks.map(\.id) == [saved.id])
    }

    @Test func deletingAFolderTakesItsBookmarksWithIt() throws {
        let store = try makeStore()
        let work = store.createFolder(named: "Work")
        try store.add(title: "One", url: url("https://one.example"), folder: work)
        try store.add(title: "Two", url: url("https://two.example"))

        store.delete(work)

        #expect(store.folders.isEmpty)
        #expect(store.rootBookmarks.map(\.title) == ["Two"])
        #expect(try store.bookmark(for: url("https://one.example")) == nil)
    }

    @Test func renamingAFolderKeepsWhatItIs() throws {
        let store = try makeStore()
        let list = store.readingListFolder()
        store.rename(list, to: "Later")

        #expect(store.folders.first?.name == "Later")
        #expect(store.folders.first?.isReadingList == true)
        // Renaming it does not strand the articles: the next add finds it by its flag.
        #expect(store.readingListFolder().id == list.id)
    }

    // MARK: - Reading list

    @Test func readingListItemsStartUnreadAndOpeningMarksThemRead() throws {
        let store = try makeStore()
        let saved = try #require(
            try store.addToReadingList(title: "Article", url: url("https://example.com/article"))
        )

        #expect(saved.isUnread)
        #expect(saved.folder?.isReadingList == true)
        #expect(store.folders.count == 1)
        #expect(store.rootBookmarks.isEmpty)
        #expect(store.readingList.map(\.id) == [saved.id])

        store.markRead(saved)
        #expect(!saved.isUnread)
        #expect(store.readingList.map(\.id) == [saved.id])

        store.setUnread(saved, true)
        #expect(saved.isUnread)
    }

    @Test func theReadingListPutsUnreadItemsFirst() throws {
        let store = try makeStore()
        let read = try #require(try store.addToReadingList(title: "Read", url: url("https://one.example")))
        let unread = try #require(try store.addToReadingList(title: "Unread", url: url("https://two.example")))
        store.markRead(read)

        #expect(store.readingList.map(\.id) == [unread.id, read.id])
    }

    @Test func oneReadingListFolderNoMatterHowManyArticles() throws {
        let store = try makeStore()
        try store.addToReadingList(title: "One", url: url("https://one.example"))
        try store.addToReadingList(title: "Two", url: url("https://two.example"))

        #expect(store.folders.filter(\.isReadingList).count == 1)
        #expect(store.readingList.count == 2)
    }

    // MARK: - Lookups

    @Test func aSavedPageIsFoundByItsExactAddress() throws {
        let store = try makeStore()
        try store.add(title: "Example", url: url("https://example.com/a"))

        #expect(try store.isBookmarked(url("https://example.com/a")))
        #expect(try !store.isBookmarked(url("https://example.com/a/")))
        #expect(try !store.isBookmarked(url("https://example.com/b")))
    }

    @Test func searchMatchesTitleAndAddress() throws {
        let store = try makeStore()
        try store.add(title: "Swift forums", url: url("https://forums.swift.org"))
        try store.add(title: "Weather", url: url("https://example.com/weather"))

        #expect(store.search("swift").map(\.title) == ["Swift forums"])
        #expect(store.search("example.com").map(\.title) == ["Weather"])
        #expect(store.search("   ").isEmpty)
    }

    @Test func deletingARowRemovesItFromTheBar() throws {
        let store = try makeStore()
        let saved = try #require(try store.add(title: "Example", url: url("https://example.com/a")))
        store.delete(saved)

        #expect(store.rootBookmarks.isEmpty)
        #expect(try store.bookmark(for: url("https://example.com/a")) == nil)
    }

    // MARK: - Row menu

    /// The menu the bar and the manager share. Named actions rather than a count, so
    /// adding a row does not fail the test but losing one does.
    @Test func everyRowOffersTheActionsTheBarPromises() throws {
        let store = try makeStore()
        let saved = try #require(try store.add(title: "Example", url: url("https://example.com/a")))
        let work = store.createFolder(named: "Work")

        let items = BookmarkRowMenu.items(for: saved, store: store, open: { _ in }, edit: {})
        let titles = items.map(\.title)
        #expect(titles.contains("Open"))
        #expect(titles.contains("Open in New Tab"))
        #expect(titles.contains("Edit…"))
        #expect(titles.contains("Delete"))
        #expect(titles.contains("Mark as Unread"))

        // The move submenu lists the bar and every folder, with the current home ticked.
        let move = try #require(items.first { $0.kind == .submenu })
        #expect(move.items.map(\.title) == ["Bookmarks Bar", work.name])
        #expect(move.items.first?.state == .radioOn)

        store.setUnread(saved, true)
        let unreadTitles = BookmarkRowMenu.items(for: saved, store: store, open: { _ in }, edit: {})
            .map(\.title)
        #expect(unreadTitles.contains("Mark as Read"))
    }

    /// A menu row whose icon name is a typo renders an empty icon slot and says nothing
    /// about it, so the names are checked here instead.
    @Test func everyRowIconIsARealSymbol() throws {
        let store = try makeStore()
        let saved = try #require(try store.add(title: "Example", url: url("https://example.com/a")))
        store.createFolder(named: "Work")

        let rows = BookmarkRowMenu.items(for: saved, store: store, open: { _ in }, edit: {})
        for icon in (rows + rows.flatMap(\.items)).compactMap(\.icon) {
            #expect(
                NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil,
                "\(icon) is not an SF Symbol"
            )
        }
    }
}

/// The V2 → V3 stage, exercised against a store the older graph actually wrote.
@MainActor
struct BookmarkMigrationTests {
    /// Writes a store with the shipping pre-bookmark schema, using the same entities the
    /// app was writing before this change.
    private func writeV2Store(at url: URL) throws -> (space: UUID, visit: UUID) {
        let ids = (space: UUID(), visit: UUID())
        try autoreleasepool {
            let schema = Schema(versionedSchema: AuraSchemaV2.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let space = TabContainer(id: ids.space, name: "Old Space")
            context.insert(space)
            let now = Date()
            try context.insert(History(
                id: ids.visit,
                url: #require(URL(string: "https://example.com/visited")),
                title: "old visit",
                createdAt: now,
                lastAccessedAt: now,
                visitCount: 1,
                container: space
            ))
            try context.save()
        }
        return ids
    }

    @Test("a store written before bookmarks existed opens through the plan")
    func aV2StoreMigratesToV3() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "aura-bookmarks-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let storeURL = root.appending(path: "OraData.sqlite")
        let ids = try writeV2Store(at: storeURL)

        let schema = Schema(versionedSchema: AuraSchemaV3.self)
        let migrated = try ModelContainer(
            for: schema,
            migrationPlan: AuraMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: storeURL)
        )
        let context = ModelContext(migrated)

        // Nothing the old graph held moved or vanished.
        #expect(try context.fetch(FetchDescriptor<TabContainer>()).map(\.id) == [ids.space])
        #expect(try context.fetch(FetchDescriptor<History>()).map(\.id) == [ids.visit])
        // The new entities start empty, which is what "no bookmarks yet" means.
        #expect(try context.fetchCount(FetchDescriptor<Bookmark>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BookmarkFolder>()) == 0)

        // And the migrated store takes a bookmark.
        let store = BookmarkStore(modelContext: context)
        let saved = try store.add(title: "Example", url: #require(URL(string: "https://example.com/a")))
        #expect(saved != nil)
        #expect(store.rootBookmarks.count == 1)
    }

    @Test func theNewStageIsNamedInTheRightOrder() {
        #expect(AuraMigrationPlan.schemas.count == AuraMigrationPlan.stages.count + 1)
        #expect(AuraSchemaV2.versionIdentifier < AuraSchemaV3.versionIdentifier)
        let entities = AuraSchemaV3.models.map { ObjectIdentifier($0) }
        #expect(entities.contains(ObjectIdentifier(Bookmark.self)))
        #expect(entities.contains(ObjectIdentifier(BookmarkFolder.self)))
        // V2 stays frozen: the stage above is only lightweight because nothing it held changed.
        #expect(!AuraSchemaV2.models.map { ObjectIdentifier($0) }.contains(ObjectIdentifier(Bookmark.self)))
    }
}
