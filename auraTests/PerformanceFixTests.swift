import Foundation
@testable import Aura
import SwiftData
import Testing

/// Checks for the behaviour that the performance pass moved into caches and predicates.
@MainActor
struct PerformanceFixTests {
    private func makeHistoryManager() throws -> (HistoryManager, TabContainer) {
        let container = try ModelContainer(
            for: TabContainer.self, History.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let space = TabContainer(name: "Perf Test Space")
        context.insert(space)
        return (HistoryManager(modelContainer: container, modelContext: context), space)
    }

    /// The title/URL match moved from an in-memory filter into the SwiftData predicate,
    /// so it has to keep matching case-insensitively on both fields.
    @Test func historySearchMatchesTitleAndURLInsideThePredicate() throws {
        let (manager, space) = try makeHistoryManager()
        try manager.record(
            title: "Swift Forums",
            url: #require(URL(string: "https://forums.swift.org/t/1")),
            container: space
        )
        try manager.record(
            title: "Hacker News",
            url: #require(URL(string: "https://news.ycombinator.com")),
            container: space
        )

        #expect(manager.search("forums", activeContainerId: space.id).map(\.title) == ["Swift Forums"])
        #expect(manager.search("YCOMBINATOR", activeContainerId: space.id).map(\.title) == ["Hacker News"])
        #expect(manager.search("nothing-here", activeContainerId: space.id).isEmpty)
        #expect(manager.search("", activeContainerId: space.id).count == 2)
    }

    /// `searchEngines` is cached now; adding or removing a custom engine must bust it.
    @Test func searchEngineListPicksUpCustomEngineChanges() {
        let service = SearchEngineService()
        let store = SettingsStore.shared
        let custom = CustomSearchEngine(
            name: "Aura Perf Test Engine",
            searchURL: "https://example.com/?q={query}",
            aliases: ["oraperftest"]
        )
        defer { store.removeCustomSearchEngine(withId: custom.id) }

        #expect(service.findSearchEngine(for: "oraperftest") == nil)

        store.addCustomSearchEngine(custom)
        #expect(service.findSearchEngine(for: "oraperftest")?.name == custom.name)

        store.removeCustomSearchEngine(withId: custom.id)
        #expect(service.findSearchEngine(for: "oraperftest") == nil)
    }

    /// A download row left as `.downloading` by a quit has no task behind it, so it can
    /// never finish. Startup has to retire it instead of putting it back on the active list.
    @Test func interruptedDownloadsDoNotComeBackAsActive() throws {
        let container = try ModelContainer(
            for: TabContainer.self, History.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let stale = Download(
            originalURL: try #require(URL(string: "https://example.com/big.zip")),
            fileName: "big.zip"
        )
        stale.status = .downloading
        context.insert(stale)
        try context.save()

        let manager = DownloadManager(modelContainer: container, modelContext: context)
        #expect(manager.activeDownloads.isEmpty)
        #expect(manager.recentDownloads.map(\.status) == [.failed])
        #expect(manager.recentDownloads.first?.error == "Interrupted by quit")

        manager.clearNonActiveDownloads()
        #expect(manager.recentDownloads.isEmpty)
    }

    /// Without a cap the header-colour retry chain reschedules itself forever.
    @Test func snapshotRetriesAreCapped() {
        #expect(Tab.maxSnapshotRetries > 0)
        #expect(Double(Tab.maxSnapshotRetries) * 0.25 <= 15.0)
    }

    /// `profileCache` kept an open `WKWebsiteDataStore` for every identifier ever used,
    /// deleted containers included. Dropping one has to release the cached profile.
    @Test func droppingAProfileReleasesTheCachedStore() {
        let engine = BrowserEngine.shared
        let identifier = UUID()
        defer { engine.dropProfile(identifier: identifier) }

        let first = engine.makeProfile(identifier: identifier, isPrivate: false)
        #expect(engine.makeProfile(identifier: identifier, isPrivate: false) === first)

        engine.dropProfile(identifier: identifier)
        #expect(engine.makeProfile(identifier: identifier, isPrivate: false) !== first)
    }

    /// `tabRefs` boxed a weak entry per tab and never dropped one. A released tab has to
    /// leave the map on the next title sync, otherwise it grows for the window's life.
    @Test func mediaControllerPrunesReleasedTabReferences() throws {
        let modelContainer = try ModelContainer(
            for: TabContainer.self, History.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(modelContainer)
        let media = MediaController()
        let manager = TabManager(
            modelContainer: modelContainer,
            modelContext: context,
            mediaController: media
        )
        let space = manager.createContainer(name: "Media Space")

        try autoreleasepool {
            let tab = try Tab(
                url: #require(URL(string: "https://example.com/song")),
                title: "song",
                container: space,
                order: 0,
                tabManager: manager,
                isPrivate: false
            )
            media.receive(
                event: MediaEventPayload(
                    type: "state",
                    wasPlayed: true,
                    state: "playing",
                    volume: nil,
                    title: nil,
                    hasNext: nil,
                    hasPrevious: nil
                ),
                from: tab
            )
            #expect(media.trackedTabCount == 1)
        }

        media.syncTitlesForPlayingSessions()
        #expect(media.trackedTabCount == 0)
    }
}
