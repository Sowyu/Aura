import Foundation
@testable import Ora
import SwiftData
import Testing

/// Sidebar tab folders: grouping, moving tabs in and out, and the two delete flavours.
@MainActor
struct TabFolderTests {
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
        let space = manager.createContainer(name: "Folder Test Space")
        return (manager, space)
    }

    private func makeTab(_ manager: TabManager, _ space: TabContainer, title: String) throws -> Tab {
        let tab = try Tab(
            url: #require(URL(string: "https://example.com/\(title)")),
            title: title,
            container: space,
            order: space.tabs.count + 1,
            tabManager: manager,
            isPrivate: false
        )
        manager.modelContext.insert(tab)
        return tab
    }

    @Test func createsAFolderAboveExistingTabs() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, title: "one")

        let folder = try #require(manager.createFolder(name: "Work", in: space))

        #expect(folder.name == "Work")
        #expect(folder.container.id == space.id)
        // The sidebar sorts descending, so a fresh folder outranks every existing tab.
        #expect(folder.order > tab.order)
        #expect(space.folders.count == 1)
    }

    @Test func movingATabInAndOutUpdatesBothSides() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, title: "one")
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        folder.isCollapsed = true

        manager.move(tab: tab, to: folder)

        #expect(tab.folder?.id == folder.id)
        #expect(folder.sortedTabs.map(\.id) == [tab.id])
        // Dropping into a collapsed folder would hide the tab you just moved.
        #expect(folder.isCollapsed == false)

        manager.move(tab: tab, to: nil)

        #expect(tab.folder == nil)
        #expect(folder.sortedTabs.isEmpty)
    }

    @Test func deletingAFolderKeepsItsTabs() throws {
        let (manager, space) = try makeManager()
        let kept = try makeTab(manager, space, title: "one")
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        manager.move(tab: kept, to: folder)

        manager.delete(folder: folder, closeTabs: false)

        #expect(space.folders.isEmpty)
        #expect(kept.folder == nil)
        #expect(space.tabs.contains { $0.id == kept.id })
    }

    @Test func renameIgnoresBlankNames() throws {
        let (manager, space) = try makeManager()
        let folder = try #require(manager.createFolder(name: "Work", in: space))

        manager.rename(folder: folder, to: "   ")
        #expect(folder.name == "Work")

        manager.rename(folder: folder, to: "  Reading  ")
        #expect(folder.name == "Reading")
    }

    @Test func pinningATabPullsItOutOfItsFolder() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, title: "one")
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        manager.move(tab: tab, to: folder)

        manager.togglePinTab(tab)

        #expect(tab.type == .pinned)
        #expect(tab.folder == nil)
        #expect(folder.sortedTabs.isEmpty)
    }
}
