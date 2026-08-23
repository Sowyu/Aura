@testable import Aura
import Foundation
import SwiftData
import Testing

/// Anchors `Bundle(for:)` on the test bundle. Swift Testing has no `XCTestCase` to hang
/// that off, and `Bundle.main` at test time is the host app, not the tests.
private final class FixtureAnchor {}

/// Reading another browser's bookmarks, and writing Aura's out again.
///
/// Every parser runs against a file shaped like the real export, quirks included, rather
/// than against a string built in the test: the failures worth catching here are the
/// ones real files cause, and a fixture written to suit the parser catches none of them.
struct BookmarkFormatTests {
    static func fixture(_ name: String, _ ext: String) throws -> Data {
        let bundle = Bundle(for: FixtureAnchor.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: ext)
                ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "\(name).\(ext) is not in the test bundle"
        )
        return try Data(contentsOf: url)
    }

    private func epoch(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    /// The whole point of committing fixtures is that the bundle carries them. xcodegen
    /// decides that from the file's extension, so a fixture in a format nobody added yet
    /// can go missing without any other test noticing.
    @Test func everyFixtureReachesTheTestBundle() throws {
        for (name, ext) in [
            ("chrome-bookmarks", "html"),
            ("firefox-bookmarks", "html"),
            ("edge-favorites", "html"),
            ("safari-bookmarks", "plist")
        ] {
            #expect(try !Self.fixture(name, ext).isEmpty, "\(name).\(ext) is empty")
        }
    }

    // MARK: - Netscape HTML

    @Test func chromeExportKeepsBarRowsOnTheBarAndFlattensDeepFolders() throws {
        let parsed = try NetscapeBookmarks.parse(Self.fixture("chrome-bookmarks", "html"))

        #expect(parsed.map(\.title) == [
            "Hacker News",
            "SwiftUI | Apple Developer",
            "Pull Requests",
            "Acme & Co \u{2122} Invoices",
            "Something to read"
        ])
        // Direct children of the toolbar folder are the bar itself.
        #expect(parsed[0].folderName == nil)
        #expect(parsed[1].folderName == nil)
        // Work/Clients/… collapses into Work rather than being dropped.
        #expect(parsed[2].folderName == "Work")
        #expect(parsed[3].folderName == "Work")
        #expect(parsed[3].urlString == "https://acme.example.com/invoices?q=open&page=2")
        // A top-level folder that is not the bar keeps its own name.
        #expect(parsed[4].folderName == "Other bookmarks")
        #expect(parsed[0].addedAt == epoch(1_704_067_200))
        #expect(parsed[2].addedAt == epoch(1_704_240_000))
    }

    /// `chrome://` pages are not pages anywhere else, and a `javascript:` bookmarklet is
    /// a saved script that would run against whatever is open when the bar is clicked.
    @Test func browserInternalPagesAndBookmarkletsAreNotImported() throws {
        let parsed = try NetscapeBookmarks.parse(Self.fixture("chrome-bookmarks", "html"))
        #expect(!parsed.contains { $0.urlString.hasPrefix("chrome:") })
        #expect(!parsed.contains { $0.urlString.hasPrefix("javascript:") })
    }

    @Test func firefoxExportSurvivesItsOwnQuirks() throws {
        let parsed = try NetscapeBookmarks.parse(Self.fixture("firefox-bookmarks", "html"))

        #expect(parsed.map(\.title) == [
            "Get Firefox",
            "Firefox Support",
            "Soup <the good one>",
            "A blog 'n stuff"
        ])
        // The `<H1 PERSONAL_TOOLBAR_FOLDER="true">` Firefox writes names the document,
        // not a folder. Reading it as one would file the whole export under "Bookmarks
        // Menu" and leave the bar empty.
        #expect(parsed[0].folderName == nil)
        #expect(parsed[1].folderName == nil)
        #expect(parsed[2].folderName == "Recipes")
        #expect(parsed[3].folderName == "Other Bookmarks")
        // `place:` queries ("Most Visited") are a Firefox view, not a page.
        #expect(!parsed.contains { $0.urlString.hasPrefix("place:") })
        // The `<HR>` separator between the first two rows is not a bookmark and does not
        // end the folder it sits in.
        #expect(parsed.count == 4)
    }

    /// Edge leaves `PERSONAL_TOOLBAR_FOLDER` off, so the folder name is the only signal
    /// that "Favorites bar" means the bar.
    @Test func edgeFavoritesBarIsFoundByName() throws {
        let parsed = try NetscapeBookmarks.parse(Self.fixture("edge-favorites", "html"))

        #expect(parsed.map(\.title) == ["Bing", "BBC News", "Outlook"])
        #expect(parsed[0].folderName == nil)
        #expect(parsed[1].folderName == "News")
        // A row sitting straight in the root list, outside any folder, is a bar row too.
        #expect(parsed[2].folderName == nil)
    }

    @Test func anEmptyOrUnparseableFileImportsNothingRatherThanThrowing() {
        #expect(NetscapeBookmarks.parse(Data()).isEmpty)
        #expect(NetscapeBookmarks.parse(Data("not markup at all".utf8)).isEmpty)
        #expect(SafariBookmarks.parse(Data("not a plist".utf8)).isEmpty)
    }

    /// A date from another epoch is worse than no date: it sorts the row to the far end
    /// of the manager and re-exports the wrong number.
    @Test func implausibleAddDatesAreDroppedNotStored() {
        #expect(NetscapeBookmarks.date(fromAddDate: "1704067200") == epoch(1_704_067_200))
        #expect(NetscapeBookmarks.date(fromAddDate: "13350000000000000") == nil)
        #expect(NetscapeBookmarks.date(fromAddDate: "0") == nil)
        #expect(NetscapeBookmarks.date(fromAddDate: "not a number") == nil)
        #expect(NetscapeBookmarks.date(fromAddDate: nil) == nil)
    }

    // MARK: - Safari

    @Test func safariPropertyListReadsTheBarTheMenuAndTheReadingList() throws {
        let parsed = try SafariBookmarks.parse(Self.fixture("safari-bookmarks", "plist"))

        #expect(parsed.map(\.title) == [
            "Apple",
            "Swift Forums",
            "Swift Evolution",
            "Wikipedia",
            "A long article"
        ])
        #expect(parsed[0].folderName == nil)
        #expect(parsed[1].folderName == "Swift")
        // BookmarksBar/Swift/Proposals flattens into Swift, the same rule the HTML
        // parser applies.
        #expect(parsed[2].folderName == "Swift")
        // Safari's internal name for the menu list, spelled the way a person reads it.
        #expect(parsed[3].folderName == "Bookmarks Menu")
        #expect(parsed[4].folderName == SafariBookmarks.readingListFolderName)
        #expect(parsed[4].addedAt == ISO8601DateFormatter().date(from: "2024-06-01T09:00:00Z"))
        // `WebBookmarkTypeProxy` rows (History, the reading-list placeholder) are not
        // bookmarks, and a leaf with a scheme Aura will not open is not one either.
        #expect(!parsed.contains { $0.title == "History" })
        #expect(!parsed.contains { $0.urlString.hasPrefix("x-apple") })
    }

    // MARK: - Export

    @Test func exportRoundTripsThroughTheParser() {
        let rows = [
            ImportedBookmark(
                title: "Hacker News",
                urlString: "https://news.ycombinator.com/",
                addedAt: epoch(1_704_067_200)
            ),
            ImportedBookmark(title: "Plain", urlString: "https://example.com/plain"),
            ImportedBookmark(
                title: "Pull Requests",
                urlString: "https://github.com/pulls",
                folderName: "Work",
                addedAt: epoch(1_704_240_000)
            ),
            ImportedBookmark(
                title: "Soup <the good one> & \"friends\"",
                urlString: "https://example.com/soup?a=1&b=2",
                folderName: "Recipes"
            )
        ]

        let reparsed = NetscapeBookmarks.parse(Data(NetscapeBookmarks.export(rows).utf8))
        #expect(reparsed == rows)
    }

    @Test func exportEscapesWhatWouldOtherwiseReopenATag() {
        let html = NetscapeBookmarks.export([
            ImportedBookmark(title: "a <b> & \"c\"", urlString: "https://example.com/?x=1&y=2")
        ])
        #expect(html.contains("a &lt;b&gt; &amp; &quot;c&quot;"))
        #expect(html.contains("HREF=\"https://example.com/?x=1&amp;y=2\""))
        // The file has to announce itself as the format, or nothing else will read it.
        #expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        #expect(html.contains("PERSONAL_TOOLBAR_FOLDER=\"true\""))
    }
}

// MARK: - Writing into the store

/// What an import does to the bookmark store.
@MainActor
struct BookmarkImportTests {
    private func makeStore() throws -> BookmarkStore {
        let container = try ModelContainer(
            for: Bookmark.self, BookmarkFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return BookmarkStore(modelContext: ModelContext(container))
    }

    @Test func importedRowsLandOnTheBarAndInFolders() throws {
        let store = try makeStore()
        let summary = BookmarkPortability.apply([
            ImportedBookmark(title: "One", urlString: "https://one.example"),
            ImportedBookmark(title: "Two", urlString: "https://two.example", folderName: "Work"),
            ImportedBookmark(title: "Three", urlString: "https://three.example", folderName: "Work")
        ], to: store)

        #expect(summary == BookmarkPortability.ImportSummary(added: 3, skipped: 0, foldersCreated: 1))
        #expect(store.rootBookmarks.map(\.title) == ["One"])
        let work = try #require(store.folders.first { $0.name == "Work" })
        #expect(store.bookmarks(in: work).map(\.title) == ["Two", "Three"])
    }

    /// Importing the same file twice is the normal way someone finds out whether an
    /// importer is safe to re-run.
    @Test func aPageAlreadySavedIsSkippedNotDuplicated() throws {
        let store = try makeStore()
        let rows = [
            ImportedBookmark(title: "One", urlString: "https://one.example"),
            ImportedBookmark(title: "Two", urlString: "https://two.example", folderName: "Work")
        ]
        BookmarkPortability.apply(rows, to: store)
        let second = BookmarkPortability.apply(rows, to: store)

        #expect(second == BookmarkPortability.ImportSummary(added: 0, skipped: 2, foldersCreated: 0))
        #expect(store.rootBookmarks.count == 1)
        #expect(store.folders.count == 1)
    }

    /// A file listing the same address twice is a file, not a bug in the store.
    @Test func duplicatesInsideOneFileCollapse() throws {
        let store = try makeStore()
        let summary = BookmarkPortability.apply([
            ImportedBookmark(title: "One", urlString: "https://one.example"),
            ImportedBookmark(title: "One again", urlString: "https://one.example", folderName: "Work")
        ], to: store)

        #expect(summary.added == 1)
        #expect(summary.skipped == 1)
        #expect(store.folders.isEmpty)
    }

    @Test func anExistingFolderIsReusedRatherThanDoubled() throws {
        let store = try makeStore()
        store.createFolder(named: "Work")
        BookmarkPortability.apply([
            ImportedBookmark(title: "Two", urlString: "https://two.example", folderName: "work")
        ], to: store)

        #expect(store.folders.map(\.name) == ["Work"])
        #expect(store.bookmarks(in: store.folders[0]).map(\.title) == ["Two"])
    }

    /// Safari's reading list is Aura's reading list, not a folder that happens to share
    /// its name, so the articles arrive unread in the list the sidebar already shows.
    @Test func aReadingListFolderIsRoutedIntoTheReadingList() throws {
        let store = try makeStore()
        BookmarkPortability.apply([
            ImportedBookmark(
                title: "A long article",
                urlString: "https://example.com/long-article",
                folderName: SafariBookmarks.readingListFolderName
            )
        ], to: store)

        #expect(store.folders.filter(\.isReadingList).count == 1)
        #expect(store.readingList.map(\.title) == ["A long article"])
        #expect(store.readingList.first?.isUnread == true)
    }

    @Test func auraInternalAddressesAreNeverImported() throws {
        let store = try makeStore()
        let summary = BookmarkPortability.apply([
            ImportedBookmark(title: "Settings", urlString: "aura://settings"),
            ImportedBookmark(title: "Real", urlString: "https://real.example")
        ], to: store)

        #expect(summary.added == 1)
        #expect(store.rootBookmarks.map(\.title) == ["Real"])
    }

    /// The full trip a user takes: a browser's file in, Aura's file out, and the same
    /// pages on the other side.
    @Test func aChromeFileImportsAndExportsBackToTheSamePages() throws {
        let store = try makeStore()
        let parsed = try NetscapeBookmarks.parse(BookmarkFormatTests.fixture("chrome-bookmarks", "html"))
        BookmarkPortability.apply(parsed, to: store)

        let exported = NetscapeBookmarks.parse(
            Data(NetscapeBookmarks.export(BookmarkPortability.exportable(from: store)).utf8)
        )
        #expect(Set(exported.map(\.urlString)) == Set(parsed.map(\.urlString)))
        #expect(Set(exported.map { $0.folderName ?? "" }) == Set(parsed.map { $0.folderName ?? "" }))
    }
}

// MARK: - Passwords

/// The CSV a password manager has to be able to read back.
struct PasswordCSVExportTests {
    /// Column names and their order are the contract with every importer that claims
    /// "Chrome CSV". Changing one turns a working import into a silent one.
    @Test func headerIsChromesColumnSet() {
        #expect(PasswordCSVExport.header == "name,url,username,password,note")
        #expect(PasswordCSVExport.csv([]).hasPrefix("name,url,username,password,note\n"))
    }

    @Test func fieldsAreQuotedOnlyWhenTheyHaveToBe() {
        #expect(PasswordCSVExport.field("plain") == "plain")
        #expect(PasswordCSVExport.field("with,comma") == "\"with,comma\"")
        #expect(PasswordCSVExport.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(PasswordCSVExport.field("two\nlines") == "\"two\nlines\"")
        // A password can begin or end with a space and the reader has to get it back.
        #expect(PasswordCSVExport.field(" padded ") == "\" padded \"")
        #expect(PasswordCSVExport.field("") == "")
    }

    /// A password full of punctuation is the case that breaks a hand-rolled exporter,
    /// and it is exactly the kind of password a generator makes.
    @Test func aNastyPasswordSurvivesTheRow() {
        let csv = PasswordCSVExport.csv([
            PasswordCSVExport.row(
                host: "example.com",
                origin: "https://example.com",
                username: "me@example.com",
                password: "a,b\"c\nd"
            )
        ])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "name,url,username,password,note")
        #expect(lines[1] == "example.com,https://example.com,me@example.com,\"a,b\"\"c")
        #expect(lines[2] == "d\",")
    }

    /// Entries saved before origins were stored carry only a host, and a CSV row with an
    /// empty URL imports into nothing.
    @Test func aRowWithoutAnOriginStillHasAnAddress() {
        let row = PasswordCSVExport.row(host: "example.com", origin: nil, username: "me", password: "x")
        #expect(row.url == "https://example.com")
        #expect(row.note.isEmpty)
    }
}

// MARK: - Settings

/// Which preferences travel, and what happens to the ones that must not.
struct SettingsBackupTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "aura.settingsbackup.\(UUID().uuidString)"
        return try (#require(UserDefaults(suiteName: suite)), suite)
    }

    /// The rule `LegacyDataMigrator` uses when it copies a whole suite: a domain's
    /// dictionary also carries the global domain, and those keys are macOS's.
    @Test func systemKeysAreNotAuraSettings() {
        #expect(!SettingsBackup.isExportable("AppleLanguages"))
        #expect(!SettingsBackup.isExportable("NSWindowFrame Main"))
        #expect(!SettingsBackup.isExportable("com.apple.trackpad.scaling"))
        #expect(SettingsBackup.isExportable("browser.homePage"))
        #expect(SettingsBackup.isExportable("settings.customSearchEngines"))
    }

    /// A security-scoped bookmark resolves on the Mac that made it and nowhere else, so
    /// importing one would point downloads at a folder the sandbox has no grant for.
    @Test func deviceBoundKeysNeverTravel() {
        #expect(!SettingsBackup.isExportable("downloads.folderBookmark"))
        #expect(!SettingsBackup.isExportable(LegacyDataMigrator.defaultsMigrationKey))
        #expect(!SettingsBackup.isExportable(SettingsStore.webKitSpellCheckKey))
    }

    @Test func exportCarriesValuesAndBlobsAndSkipsTheRest() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "browser.restoreTabsOnLaunch")
        defaults.set("https://example.com", forKey: "browser.homePage")
        defaults.set(12, forKey: "tabs.maxLive")
        defaults.set(Data("[]".utf8), forKey: "settings.customSearchEngines")
        defaults.set(Data([0x01, 0x02]), forKey: "downloads.folderBookmark")

        let document = try #require(
            try JSONSerialization.jsonObject(with: SettingsBackup.export(from: defaults)) as? [String: Any]
        )
        let values = try #require(document["values"] as? [String: Any])
        let blobs = try #require(document["data"] as? [String: String])

        #expect(document["format"] as? Int == SettingsBackup.formatVersion)
        #expect(values["browser.homePage"] as? String == "https://example.com")
        #expect(values["browser.restoreTabsOnLaunch"] as? Bool == true)
        #expect(values["tabs.maxLive"] as? Int == 12)
        // Settings stored as one JSON blob arrive as `Data`, which JSON has no type for.
        #expect(blobs["settings.customSearchEngines"] == Data("[]".utf8).base64EncodedString())
        #expect(blobs["downloads.folderBookmark"] == nil)
        #expect(values["downloads.folderBookmark"] == nil)
        #expect(!values.keys.contains { SettingsBackup.isSystemKey($0) })
    }

    /// An import is a merge. Anything the file does not name is the user's current
    /// setting and stays that way.
    @Test func importWritesOnlyTheKeysTheFileNames() throws {
        let (source, sourceSuite) = try makeDefaults()
        let (target, targetSuite) = try makeDefaults()
        defer {
            source.removePersistentDomain(forName: sourceSuite)
            target.removePersistentDomain(forName: targetSuite)
        }

        source.set("https://example.com", forKey: "browser.homePage")
        source.set(Data("[1]".utf8), forKey: "settings.customKeyboardShortcuts")
        target.set("kept", forKey: "browser.externalLinkTarget")
        target.set("https://old.example", forKey: "browser.homePage")

        let applied = try SettingsBackup.apply(SettingsBackup.export(from: source), to: target)

        #expect(applied >= 2)
        #expect(target.string(forKey: "browser.homePage") == "https://example.com")
        #expect(target.data(forKey: "settings.customKeyboardShortcuts") == Data("[1]".utf8))
        #expect(target.string(forKey: "browser.externalLinkTarget") == "kept")
    }

    /// A file that names an excluded key was written by hand, and the exclusion is the
    /// point of the exclusion.
    @Test func anExcludedKeyIsIgnoredEvenWhenTheFileNamesIt() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let document: [String: Any] = [
            "format": 1,
            "values": ["AppleLanguages": ["fr"], "browser.homePage": "https://ok.example"],
            "data": ["downloads.folderBookmark": Data([0x09]).base64EncodedString()]
        ]
        let applied = try SettingsBackup.apply(
            JSONSerialization.data(withJSONObject: document),
            to: defaults
        )

        #expect(applied == 1)
        #expect(defaults.string(forKey: "browser.homePage") == "https://ok.example")
        #expect(defaults.data(forKey: "downloads.folderBookmark") == nil)
    }

    @Test func aFileThatIsNotASettingsExportIsRejected() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(throws: SettingsBackupError.self) {
            try SettingsBackup.apply(Data("[]".utf8), to: defaults)
        }
        #expect(throws: SettingsBackupError.self) {
            try SettingsBackup.apply(Data("{\"values\":{}}".utf8), to: defaults)
        }
        #expect(throws: SettingsBackupError.self) {
            try SettingsBackup.apply(
                JSONSerialization.data(withJSONObject: ["format": 99, "values": [:] as [String: Any]]),
                to: defaults
            )
        }
    }
}

// MARK: - Onboarding

struct FirstRunCardTests {
    /// Both halves matter and both are invisible when wrong: a card that keeps coming
    /// back after "no", or one that never shows because Aura is already the default on
    /// the machine it was written on.
    @Test func theCardShowsOnlyWhenAuraIsNotDefaultAndNobodyDismissedIt() {
        #expect(FirstRunCardPolicy.isVisible(isDefaultBrowser: false, wasDismissed: false))
        #expect(!FirstRunCardPolicy.isVisible(isDefaultBrowser: true, wasDismissed: false))
        #expect(!FirstRunCardPolicy.isVisible(isDefaultBrowser: false, wasDismissed: true))
        #expect(!FirstRunCardPolicy.isVisible(isDefaultBrowser: true, wasDismissed: true))
    }

    /// Dismissal is persisted, not per-window: the flag has to round trip through
    /// `UserDefaults` or the card returns on the next launch.
    @Test func dismissalIsRememberedUnderItsOwnKey() throws {
        let suite = "aura.firstrun.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(defaults.bool(forKey: "browser.firstRunCard.dismissed") == false)
        defaults.set(true, forKey: "browser.firstRunCard.dismissed")
        #expect(defaults.bool(forKey: "browser.firstRunCard.dismissed"))
        #expect(SettingsBackup.isExportable("browser.firstRunCard.dismissed"))
    }
}
