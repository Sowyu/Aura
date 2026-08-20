import Foundation
@testable import Aura
import SwiftData
import Testing

/// New tabs land on `aura://home` rather than a blank web view.
@MainActor
struct HomeTabTests {
    private func makeManager() throws -> (TabManager, TabContainer) {
        let modelContainer = try ModelContainer(
            for: TabContainer.self, History.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(modelContainer)
        let manager = TabManager(
            modelContainer: modelContainer,
            modelContext: context,
            mediaController: MediaController()
        )
        return (manager, manager.createContainer(name: "Home Test Space"))
    }

    @Test func addTabWithoutAURLOpensHome() throws {
        let (manager, space) = try makeManager()

        let tab = manager.addTab(container: space, isPrivate: false)

        #expect(tab.url.isOraHome)
        #expect(tab.url == URL.oraHome)
        #expect(tab.title == "New Tab")
        #expect(tab.favicon == nil)
        // Internal pages never get a web view, so nothing is loaded into WebKit.
        #expect(tab.browserPage == nil)
    }

    @Test func openHomeTabActivatesItInTheCurrentSpace() throws {
        let (manager, space) = try makeManager()

        let tab = try #require(manager.openHomeTab(isPrivate: false))

        #expect(tab.container.id == space.id)
        #expect(manager.activeTab?.id == tab.id)
        #expect(tab.url.isOraHome)
    }
}
