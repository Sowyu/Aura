import Foundation
@testable import Ora
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
            name: "Ora Perf Test Engine",
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

    /// Without a cap the header-colour retry chain reschedules itself forever.
    @Test func snapshotRetriesAreCapped() {
        #expect(Tab.maxSnapshotRetries > 0)
        #expect(Double(Tab.maxSnapshotRetries) * 0.25 <= 15.0)
    }
}
