@testable import Aura
import Foundation
import SwiftData
import Testing

/// Reopening a closed tab has to make room for it. Folders sit among the normal tabs and
/// share `Tab.order`'s scale, so they get shifted with the tabs or the restored tab lands
/// on top of one.
@MainActor
struct RestoredTabOrderTests {
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
        return (manager, manager.createContainer(name: "Restore Space"))
    }

    @discardableResult
    private func makeTab(
        _ manager: TabManager,
        _ space: TabContainer,
        order: Int,
        type: TabType = .normal
    ) throws -> Tab {
        let tab = try Tab(
            url: #require(URL(string: "https://example.com/\(order)")),
            title: "tab \(order)",
            container: space,
            type: type,
            order: order,
            tabManager: manager,
            isPrivate: false
        )
        manager.modelContext.insert(tab)
        space.tabs.append(tab)
        try manager.modelContext.save()
        return tab
    }

    /// Let deferred lifecycle callbacks settle before inspecting the model.
    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func batchedCloseReportsEachDeletedTabOnce() throws {
        let (manager, space) = try makeManager()
        let first = try makeTab(manager, space, order: 1)
        let second = try makeTab(manager, space, order: 2)
        let expected = Set([first.id, second.id])
        let deleted = [first, second]
            .flatMap { manager.closeTab(tab: $0, shouldTrackForRestore: false, persist: false) }
        try manager.modelContext.save()
        manager.announceDeletedTabs(deleted)
        #expect(Set(deleted) == expected)
        #expect(deleted.count == 2)
        #expect(space.tabs.isEmpty)
    }

    @Test func restoringANormalTabPushesFoldersDownTheSameWayItPushesTabs() async throws {
        let (manager, space) = try makeManager()
        let below = try makeTab(manager, space, order: 1)
        let above = try makeTab(manager, space, order: 5)
        let untouched = try #require(manager.createFolder(name: "Above", in: space))
        untouched.order = 1
        let shifted = try #require(manager.createFolder(name: "At the gap", in: space))
        shifted.order = 3
        let alsoShifted = try #require(manager.createFolder(name: "Below the gap", in: space))
        alsoShifted.order = 7

        let closing = try makeTab(manager, space, order: 3)
        manager.closeTab(tab: closing)
        await settle()
        manager.restoreLastTab()

        let restored = try #require(space.tabs.first { $0.title == "tab 3" })
        #expect(restored.order == 3)
        #expect(below.order == 1, "a tab below the gap does not move")
        #expect(above.order == 6, "a tab at or past the gap moves up one")
        #expect(untouched.order == 1, "a folder below the gap does not move")
        #expect(shifted.order == 4, "a folder sitting on the restored order moves up one")
        #expect(alsoShifted.order == 8)
        // Nothing may share the restored tab's slot.
        let occupants = space.tabs.filter { $0.type == .normal && $0.order == restored.order }.count
            + space.folders.filter { $0.order == restored.order }.count
        #expect(occupants == 1)
    }

    @Test func theShiftStaysInsideTheNormalTabSection() async throws {
        let (manager, space) = try makeManager()
        // Pinned tabs have their own order scale above the normal ones, and a folder
        // below the gap is not in the way, so neither may move.
        let pinned = try makeTab(manager, space, order: 2, type: .pinned)
        let folderBelow = try #require(manager.createFolder(name: "Below", in: space))
        folderBelow.order = 1

        let closing = try makeTab(manager, space, order: 2)
        manager.closeTab(tab: closing)
        await settle()
        manager.restoreLastTab()

        #expect(pinned.order == 2)
        #expect(folderBelow.order == 1)
        #expect(space.tabs.first { $0.type == .normal }?.order == 2)
    }

    @Test func deletingPinnedTabKeepsItsRestoreType() async throws {
        let (manager, space) = try makeManager()
        let pinned = try makeTab(manager, space, order: 3, type: .pinned)
        let id = pinned.id
        manager.deleteTab(tab: pinned)
        await settle()
        manager.restoreLastTab()
        let restored = try #require(space.tabs.first { $0.id == id || $0.title == "tab 3" })
        #expect(restored.type == .pinned)
    }

    @Test func numberedTabsFollowFoldersInSidebarOrder() throws {
        let (manager, space) = try makeManager()
        let first = try makeTab(manager, space, order: 8)
        let last = try makeTab(manager, space, order: 1)
        let folder = try #require(manager.createFolder(name: "Middle", in: space))
        folder.order = 4
        let child = try makeTab(manager, space, order: 20)
        child.folder = folder
        folder.tabs = [child]
        manager.activeContainer = space
        #expect(manager.orderedTabs.map(\.id) == [first.id, child.id, last.id])
    }
}
