import AppKit
@testable import Aura
import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers

/// What the address field does with a path: which forms become a file, which stay a
/// search, and how a space in a name survives the round trip.
struct LocalFileURLTests {
    private let home = "/Users/tester"

    @Test func anAbsolutePathBecomesAFileURL() throws {
        let url = try #require(localFileURL(from: "/etc/hosts", home: home))
        #expect(url.isFileURL)
        #expect(url.path == "/etc/hosts")
        #expect(constructURL(from: "/etc/hosts") == url)
    }

    @Test func aTildePathExpandsAgainstTheGivenHome() throws {
        let url = try #require(localFileURL(from: "~/Documents/report.pdf", home: home))
        #expect(url.path == "/Users/tester/Documents/report.pdf")
        #expect(try #require(localFileURL(from: "~", home: home)).path == home)
    }

    /// The example from the plan, both ways round: a typed path with a space and the
    /// encoded URL of the same file have to name one file.
    @Test func aSpaceInAPathEncodesOnceAndOnlyOnce() throws {
        let typed = try #require(localFileURL(from: "/Users/aniko/Year 9/Chapter-4-Worked-Solutions.pdf", home: home))
        #expect(typed.absoluteString == "file:///Users/aniko/Year%209/Chapter-4-Worked-Solutions.pdf")

        let encoded = try #require(
            localFileURL(from: "file:///Users/aniko/Year%209/Chapter-4-Worked-Solutions.pdf", home: home)
        )
        #expect(encoded == typed)
        #expect(encoded.path == "/Users/aniko/Year 9/Chapter-4-Worked-Solutions.pdf")
    }

    @Test func aFileURLWithLiteralSpacesIsAcceptedToo() throws {
        let url = try #require(localFileURL(from: "file:///Users/aniko/Year 9/Ch 4.pdf", home: home))
        #expect(url.path == "/Users/aniko/Year 9/Ch 4.pdf")
        #expect(url.absoluteString == "file:///Users/aniko/Year%209/Ch%204.pdf")
    }

    @Test func theLocalhostFormNamesTheSameFile() throws {
        let plain = try #require(localFileURL(from: "file:///tmp/a.txt", home: home))
        #expect(localFileURL(from: "file://localhost/tmp/a.txt", home: home) == plain)
    }

    /// `report.pdf#page=3` is how a PDF viewer is told where to open, so the fragment is
    /// the URL's and not part of the file name.
    @Test func aFragmentSurvives() throws {
        let url = try #require(localFileURL(from: "file:///tmp/report.pdf#page=3", home: home))
        #expect(url.fragment == "page=3")
        #expect(url.path == "/tmp/report.pdf")
    }

    @Test func aRelativePathIsStillASearch() {
        #expect(localFileURL(from: "notes/todo.md", home: home) == nil)
        #expect(localFileURL(from: "readme.txt", home: home) == nil)
        #expect(constructURL(from: "notes/todo.md") == nil)
        #expect(isValidURL("notes/todo.md") == false)
    }

    /// A scheme-relative address is not a path with two slashes in front of it.
    @Test func aSchemeRelativeAddressIsNotAPath() {
        #expect(localFileURL(from: "//example.com/page", home: home) == nil)
    }

    @Test func ordinaryAddressesAreUnchanged() throws {
        #expect(constructURL(from: "https://example.com")?.absoluteString == "https://example.com")
        #expect(constructURL(from: "example.com")?.absoluteString == "https://example.com")
        #expect(constructURL(from: "localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(try #require(constructURL(from: "aura://home")).isOraInternal)
    }

    /// The launcher only builds a URL for text `isValidURL` accepts, so a path has to
    /// read as an address there or ⌘T offers a web search for a file on disk.
    @Test func aPathReadsAsAnAddressNotAQuery() {
        #expect(isValidURL("/etc/hosts"))
        #expect(isValidURL("~/Documents/report.pdf"))
        #expect(isValidURL("file:///tmp/a.txt"))
    }

    @Test func theRealHomeIsNotTheSandboxContainer() {
        // Whatever it is, it is an absolute path and it is not empty. The point of the
        // helper is that it does not come from `NSHomeDirectory`, which a sandboxed
        // process answers with its container.
        #expect(realHomeDirectory().hasPrefix("/"))
    }
}

/// Inline or download, the rule `BrowserPage` applies to every navigation response.
/// The MIME type reaches it through `canShowMIMEType`; the values below are the ones
/// WebKit reported for those types in a WKWebView harness on this OS.
struct FileResponsePolicyTests {
    @Test func whatWebKitCanDrawIsDrawn() {
        // application/pdf, image/png, text/markdown, text/html: canShowMIMEType true.
        #expect(BrowserPage.responseDisposition(canShowMIMEType: true, contentDisposition: nil) == .inline)
    }

    @Test func whatWebKitCannotDrawGoesToDownloads() {
        // application/zip: canShowMIMEType false, over http and over file:// alike.
        #expect(BrowserPage.responseDisposition(canShowMIMEType: false, contentDisposition: nil) == .download)
    }

    @Test func anAttachmentHeaderBeatsATypeWebKitCouldDraw() {
        let policy = BrowserPage.responseDisposition(
            canShowMIMEType: true,
            contentDisposition: "attachment; filename=\"forced.pdf\""
        )
        #expect(policy == .download)
    }

    @Test func theHeaderIsMatchedWhateverItsCase() {
        #expect(
            BrowserPage.responseDisposition(canShowMIMEType: true, contentDisposition: "ATTACHMENT")
                == .download
        )
    }

    /// `inline` is the other value the header takes, and it must not push a renderable
    /// response into the download flow.
    @Test func anInlineHeaderChangesNothing() {
        let policy = BrowserPage.responseDisposition(
            canShowMIMEType: true,
            contentDisposition: "inline; filename=\"report.pdf\""
        )
        #expect(policy == .inline)
    }
}

/// What a drop carries, and the one ordering rule that matters: Aura's own rows first.
struct DropPayloadTests {
    @Test func auraOwnRowWinsOverEveryOtherTypeOnThePasteboard() {
        // A tab drag advertises public.url and public.utf8-plain-text as well, so a
        // receiver reading URLs first would open the row it is reordering.
        let payload = DropPayloadReader.classify(
            hasTabItem: true,
            fileURLs: [URL(fileURLWithPath: "/tmp/a.pdf")],
            urlString: "https://example.com",
            text: "https://example.com"
        )
        #expect(payload == .tabItem)
    }

    @Test func aDroppedFileIsAFileDrop() {
        let file = URL(fileURLWithPath: "/tmp/a.pdf")
        #expect(
            DropPayloadReader.classify(hasTabItem: false, fileURLs: [file], urlString: nil, text: nil)
                == .files([file])
        )
    }

    @Test func aDroppedAddressIsAnAddress() throws {
        let payload = DropPayloadReader.classify(
            hasTabItem: false,
            fileURLs: [],
            urlString: "https://example.com/a",
            text: "https://example.com/a"
        )
        let expected = try #require(URL(string: "https://example.com/a"))
        #expect(payload == .url(expected))
    }

    @Test func droppedTextThatIsNotAnAddressIsASearch() {
        let payload = DropPayloadReader.classify(
            hasTabItem: false,
            fileURLs: [],
            urlString: nil,
            text: "  when did the roman empire fall  "
        )
        #expect(payload == .search("when did the roman empire fall"))
    }

    @Test func droppedTextThatIsAnAddressIsOpened() throws {
        let payload = DropPayloadReader.classify(
            hasTabItem: false, fileURLs: [], urlString: nil, text: "example.com/a"
        )
        let expected = try #require(URL(string: "https://example.com/a"))
        #expect(payload == .url(expected))
    }

    /// A path dragged out of a terminal arrives as text, not as a file URL.
    @Test func droppedTextThatIsAPathIsAFile() {
        let payload = DropPayloadReader.classify(
            hasTabItem: false, fileURLs: [], urlString: nil, text: "/tmp/report.pdf"
        )
        #expect(payload == .files([URL(fileURLWithPath: "/tmp/report.pdf")]))
    }

    @Test func anEmptyDropCarriesNothing() {
        #expect(DropPayloadReader.classify(hasTabItem: false, fileURLs: [], urlString: nil, text: "   ") == .nothing)
    }
}

/// The tray: what a row records, when it goes, and what a pin protects.
@MainActor
struct OpenedFileStoreTests {
    private func makeStore() throws -> OpenedFileStore {
        let container = try ModelContainer(
            for: OpenedFile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return OpenedFileStore(context: ModelContext(container))
    }

    private var chapter: URL {
        URL(fileURLWithPath: "/Users/aniko/Documents/Subjects/Patrick/Year 9/Chapter-4-Worked-Solutions.pdf")
    }

    @Test func openingAFileRecordsItsEncodedLocationVerbatim() throws {
        let store = try makeStore()
        let row = try #require(store.record(chapter, tabID: UUID()))

        #expect(row.displayName == "Chapter-4-Worked-Solutions.pdf")
        #expect(
            row.locationString
                == "file:///Users/aniko/Documents/Subjects/Patrick/Year%209/Chapter-4-Worked-Solutions.pdf"
        )
        #expect(row.path == "/Users/aniko/Documents/Subjects/Patrick/Year 9/Chapter-4-Worked-Solutions.pdf")
        #expect(row.url == chapter)
        #expect(store.entries.count == 1)
    }

    @Test func openingTheSameFileTwiceMovesTheRowInsteadOfAddingOne() throws {
        let store = try makeStore()
        let first = try #require(store.record(chapter, tabID: UUID(), openedAt: Date(timeIntervalSince1970: 1)))
        let secondTab = UUID()
        let second = try #require(store.record(chapter, tabID: secondTab, openedAt: Date(timeIntervalSince1970: 2)))

        #expect(first.path == second.path)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.tabID == secondTab)
    }

    /// A path with a `..` in it is the same file as the one without.
    @Test func aPathIsStandardizedBeforeItBecomesARow() throws {
        let store = try makeStore()
        store.record(URL(fileURLWithPath: "/tmp/a.pdf"))
        store.record(URL(fileURLWithPath: "/tmp/sub/../a.pdf"))
        #expect(store.entries.count == 1)
    }

    @Test func closingTheTabRemovesAnUnpinnedRow() throws {
        let store = try makeStore()
        let tab = UUID()
        store.record(chapter, tabID: tab)
        store.tabClosed(tab)

        #expect(store.entries.isEmpty)
    }

    @Test func aPinnedRowSurvivesItsTabClosing() throws {
        let store = try makeStore()
        let tab = UUID()
        let row = try #require(store.record(chapter, tabID: tab))
        store.setPinned(row, true)
        store.tabClosed(tab)

        #expect(store.entries.count == 1)
        #expect(store.entries.first?.isPinned == true)
        // And it is no longer claimed by a tab that has gone.
        #expect(store.entries.first?.tabID == nil)
    }

    @Test func anotherTabsRowIsLeftAlone() throws {
        let store = try makeStore()
        let mine = UUID()
        store.record(chapter, tabID: mine)
        store.record(URL(fileURLWithPath: "/tmp/other.txt"), tabID: UUID())
        store.tabClosed(mine)

        #expect(store.entries.map(\.displayName) == ["other.txt"])
    }

    @Test func pinnedRowsSortAboveTheRest() throws {
        let store = try makeStore()
        let older = Date(timeIntervalSince1970: 1)
        let old = try #require(store.record(URL(fileURLWithPath: "/tmp/old.txt"), openedAt: older))
        store.record(URL(fileURLWithPath: "/tmp/new.txt"), openedAt: Date(timeIntervalSince1970: 9))
        store.setPinned(old, true)

        #expect(store.entries.map(\.displayName) == ["old.txt", "new.txt"])
    }

    @Test func clearingKeepsThePins() throws {
        let store = try makeStore()
        let kept = try #require(store.record(URL(fileURLWithPath: "/tmp/keep.txt")))
        store.record(URL(fileURLWithPath: "/tmp/drop.txt"))
        store.setPinned(kept, true)
        store.clearUnpinned()

        #expect(store.entries.map(\.displayName) == ["keep.txt"])
    }

    @Test func removingARowDropsIt() throws {
        let store = try makeStore()
        let row = try #require(store.record(chapter))
        store.remove(row)

        #expect(store.entries.isEmpty)
        #expect(store.entry(for: chapter) == nil)
    }

    /// Only files. An http address is a bookmark's business.
    @Test func aWebAddressIsNotATrayRow() throws {
        let store = try makeStore()
        let webAddress = try #require(URL(string: "https://example.com"))
        #expect(store.record(webAddress) == nil)
        #expect(store.entries.isEmpty)
    }
}

/// The bookmark table behind the tray. `makeBookmark` and `resolveBookmark` are injected,
/// the way `SecurityScopedFolder` injects start and stop, so the behaviour can be
/// exercised without a sandbox to hand out real grants.
@MainActor
struct FileAccessStoreTests {
    /// A store over its own defaults suite, and the suite name so the test can throw it
    /// away afterwards.
    private struct Fixture {
        let store: FileAccessStore
        let defaults: UserDefaults
        let suite: String

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makeStore(resolves: Bool = true) -> Fixture {
        let suite = "ws7-file-access-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let store = FileAccessStore(
            defaults: defaults,
            makeBookmark: { url in Data(url.path.utf8) },
            resolveBookmark: { data in
                guard resolves, let path = String(data: data, encoding: .utf8) else { return nil }
                return (URL(fileURLWithPath: path), false)
            },
            start: { _ in true }
        )
        return Fixture(store: store, defaults: defaults, suite: suite)
    }

    @Test func rememberingAFileWritesABookmarkUnderItsPath() {
        let fixture = makeStore()
        let (store, defaults) = (fixture.store, fixture.defaults)
        defer { fixture.tearDown() }

        store.remember(URL(fileURLWithPath: "/tmp/a.pdf"))

        #expect(store.bookmarks["/tmp/a.pdf"] != nil)
        #expect((defaults.dictionary(forKey: FileAccessStore.bookmarksKey) as? [String: Data])?.count == 1)
    }

    @Test func aWebAddressIsNotBookmarked() throws {
        let fixture = makeStore()
        let (store, defaults) = (fixture.store, fixture.defaults)
        defer { fixture.tearDown() }

        let webAddress = try #require(URL(string: "https://example.com"))
        store.remember(webAddress)
        #expect(store.bookmarks.isEmpty)
    }

    @Test func accessOpensFromAStoredBookmark() {
        let fixture = makeStore()
        let (store, defaults) = (fixture.store, fixture.defaults)
        defer { fixture.tearDown() }
        let file = URL(fileURLWithPath: "/tmp/a.pdf")

        #expect(store.beginAccess(to: file) == false)
        store.remember(file)
        #expect(store.beginAccess(to: file))
    }

    @Test func forgettingRemovesTheGrant() {
        let fixture = makeStore()
        let (store, defaults) = (fixture.store, fixture.defaults)
        defer { fixture.tearDown() }
        let file = URL(fileURLWithPath: "/tmp/a.pdf")

        store.remember(file)
        store.forget(file)
        #expect(store.bookmarks.isEmpty)
        #expect((defaults.dictionary(forKey: FileAccessStore.bookmarksKey) as? [String: Data])?.isEmpty == true)
    }

    /// A grant nothing can reach any more is a permission the user can neither see nor
    /// revoke, so the sweep takes it with the row.
    @Test func pruneDropsGrantsTheTrayNoLongerHolds() {
        let fixture = makeStore()
        let (store, defaults) = (fixture.store, fixture.defaults)
        defer { fixture.tearDown() }

        store.remember(URL(fileURLWithPath: "/tmp/kept.pdf"))
        store.remember(URL(fileURLWithPath: "/tmp/gone.pdf"))
        store.prune(keeping: ["/tmp/kept.pdf"])

        #expect(Array(store.bookmarks.keys) == ["/tmp/kept.pdf"])
    }

    @Test func aBookmarkThatNoLongerResolvesIsPrunedEvenWhenTheRowIsKept() {
        let fixture = makeStore(resolves: false)
        let store = fixture.store
        defer { fixture.tearDown() }

        store.remember(URL(fileURLWithPath: "/tmp/kept.pdf"))
        store.prune(keeping: ["/tmp/kept.pdf"])

        #expect(store.bookmarks.isEmpty)
    }

    /// The tests run outside the sandbox, which is the case where a readable file needs
    /// no permission of any kind.
    @Test func areadableFileNeedsNoConsent() throws {
        let fixture = makeStore()
        let (store, defaults) = (fixture.store, fixture.defaults)
        defer { fixture.tearDown() }

        let temp = FileManager.default.temporaryDirectory.appending(path: "ws7-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        #expect(store.needsConsent(for: temp) == false)
        #expect(store.needsConsent(for: URL(fileURLWithPath: "/nope/\(UUID().uuidString)")))
    }
}

// MARK: - Migration

/// The V4 → V5 stage, exercised against a store the older graph actually wrote.
@MainActor
struct OpenedFileMigrationTests {
    /// What the old store was written with, so the migrated one can be checked against it.
    private struct FixtureIDs {
        let space = UUID()
        let bookmark = UUID()
        let tab = UUID()
    }

    private func writeV4Store(at url: URL) throws -> FixtureIDs {
        let ids = FixtureIDs()
        try autoreleasepool {
            let schema = Schema(versionedSchema: AuraSchemaV4.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            context.insert(TabContainer(id: ids.space, name: "Old Space"))
            context.insert(Bookmark(id: ids.bookmark, title: "Saved", urlString: "https://example.com/saved"))
            context.insert(TabSession(tabID: ids.tab, interactionState: Data([9]), scrollY: 12))
            try context.save()
        }
        return ids
    }

    @Test("a store written before the file tray existed opens through the plan")
    func aV4StoreMigratesToV5() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "aura-files-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let storeURL = root.appending(path: "OraData.sqlite")
        let ids = try writeV4Store(at: storeURL)

        let schema = Schema(versionedSchema: AuraSchemaV5.self)
        let migrated = try ModelContainer(
            for: schema,
            migrationPlan: AuraMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: storeURL)
        )
        let context = ModelContext(migrated)

        // Nothing the old graph held moved or vanished.
        #expect(try context.fetch(FetchDescriptor<TabContainer>()).map(\.id) == [ids.space])
        #expect(try context.fetch(FetchDescriptor<Bookmark>()).map(\.id) == [ids.bookmark])
        #expect(try context.fetch(FetchDescriptor<TabSession>()).map(\.tabID) == [ids.tab])
        // The new entity starts empty, which is what "no files opened yet" means.
        #expect(try context.fetchCount(FetchDescriptor<OpenedFile>()) == 0)

        // And the migrated store takes a row.
        context.insert(OpenedFile.make(for: URL(fileURLWithPath: "/tmp/a.pdf")))
        try context.save()
        let saved = try #require(try context.fetch(FetchDescriptor<OpenedFile>()).first)
        #expect(saved.locationString == "file:///tmp/a.pdf")
    }

    @Test func theNewStageIsNamedInTheRightOrder() {
        #expect(AuraMigrationPlan.schemas.count == AuraMigrationPlan.stages.count + 1)
        #expect(AuraSchemaV4.versionIdentifier < AuraSchemaV5.versionIdentifier)
        #expect(AuraSchemaV5.models.map { ObjectIdentifier($0) }.contains(ObjectIdentifier(OpenedFile.self)))
        // V4 stays frozen: the stage above is only lightweight because nothing it held
        // changed, and it names the live `Tab` class among others.
        #expect(!AuraSchemaV4.models.map { ObjectIdentifier($0) }.contains(ObjectIdentifier(OpenedFile.self)))
    }
}

/// Zoom against a local file. WebKit's PDF view honours `pageZoom` (measured), but a
/// `file://` URL has no registrable domain, so the level needs a key of its own or the
/// shortcut writes nothing and the page never moves.
@MainActor
struct LocalFileZoomTests {
    @Test func aLocalFileHasAZoomKeyOfItsOwn() {
        #expect(SiteZoomController.zoomKey(for: URL(fileURLWithPath: "/tmp/a.pdf")) == "file://")
        // Every local file shares it, so the level is "how I read documents".
        #expect(
            SiteZoomController.zoomKey(for: URL(fileURLWithPath: "/tmp/a.pdf"))
                == SiteZoomController.zoomKey(for: URL(fileURLWithPath: "/other/b.pdf"))
        )
    }

    @Test func aWebAddressStillKeysOnItsSite() throws {
        let url = try #require(URL(string: "https://news.bbc.co.uk/story"))
        #expect(SiteZoomController.zoomKey(for: url) == "bbc.co.uk")
    }

    /// The key has a colon in it, which no host name can, so it cannot collide with a
    /// site's stored level.
    @Test func theLocalKeySurvivesTheSettingsNormalizer() {
        SettingsStore.shared.setZoomLevel(1.5, forHost: "file://")
        #expect(SettingsStore.shared.zoomLevel(forHost: "file://") == 1.5)
        #expect(SiteZoomController.level(for: URL(fileURLWithPath: "/tmp/a.pdf")) == 1.5)
        SettingsStore.shared.setZoomLevel(SiteZoom.default, forHost: "file://")
        #expect(SiteZoomController.level(for: URL(fileURLWithPath: "/tmp/a.pdf")) == SiteZoom.default)
    }
}
