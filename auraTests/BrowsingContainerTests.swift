import Foundation
import Observation
@testable import Aura
import SwiftData
import Testing

/// Firefox-style containers: creation, the per-space default, moving a tab between
/// stores, and the one-shot migration that turns every old space store into a container.
@MainActor
struct BrowsingContainerTests {
    private func makeManagers() throws -> (TabManager, ContainerManager, TabContainer) {
        let modelContainer = try ModelContainer(
            for: TabContainer.self, History.self, Download.self, BrowsingContainer.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(modelContainer)
        let tabManager = TabManager(
            modelContainer: modelContainer,
            modelContext: context,
            mediaController: MediaController()
        )
        let containerManager = ContainerManager(modelContext: context)
        let space = tabManager.createContainer(name: "Container Test Space")
        return (tabManager, containerManager, space)
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
        space.tabs.append(tab)
        return tab
    }

    /// A throwaway domain so the migration flag from one test cannot silence another.
    private func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "aura.tests.\(UUID().uuidString)"))
    }

    @Test func createsAContainerWithItsOwnStore() throws {
        let (_, containers, _) = try makeManagers()

        let work = containers.create(name: "Work", colorHex: BrowsingContainer.palette[1], iconSymbol: "briefcase.fill")

        #expect(work.name == "Work")
        #expect(work.colorHex == BrowsingContainer.palette[1])
        #expect(containers.containers.map(\.id) == [work.id])

        let personal = containers.create(name: "Personal")
        #expect(personal.storeIdentifier != work.storeIdentifier)
        #expect(containers.containers.map(\.order) == [0, 1])
    }

    @Test func aTabWithNoContainerUsesTheSharedDefaultStore() throws {
        let (manager, _, space) = try makeManagers()
        let tab = try makeTab(manager, space, title: "loose")

        #expect(tab.browsingContainer == nil)
        #expect(tab.storeIdentifier == BrowserEngine.defaultStoreIdentifier)
    }

    @Test func newTabsInheritTheSpaceDefault() throws {
        let (manager, containers, space) = try makeManagers()
        let work = containers.create(name: "Work")
        containers.setDefault(work, for: space)

        let tab = manager.addTab(container: space, isPrivate: false)

        #expect(tab.browsingContainer?.id == work.id)
        #expect(tab.storeIdentifier == work.storeIdentifier)

        // A duplicate rides along with the tab it was made from.
        let copy = manager.duplicateTab(tab)
        #expect(copy.browsingContainer?.id == work.id)
    }

    @Test func movingATabChangesItsStoreIdentifier() throws {
        let (manager, containers, space) = try makeManagers()
        let work = containers.create(name: "Work")
        let shopping = containers.create(name: "Shopping")
        let tab = try makeTab(manager, space, title: "one")

        containers.move(tab, to: work)
        #expect(tab.storeIdentifier == work.storeIdentifier)

        containers.move(tab, to: shopping)
        #expect(tab.storeIdentifier == shopping.storeIdentifier)

        containers.move(tab, to: nil)
        #expect(tab.browsingContainer == nil)
        #expect(tab.storeIdentifier == BrowserEngine.defaultStoreIdentifier)
    }

    @Test func deletingAContainerClearsTabsAndTheSpaceDefault() throws {
        let (manager, containers, space) = try makeManagers()
        let work = containers.create(name: "Work")
        containers.setDefault(work, for: space)
        let tab = try makeTab(manager, space, title: "one")
        containers.move(tab, to: work)

        containers.delete(work)

        #expect(containers.containers.isEmpty)
        #expect(tab.browsingContainer == nil)
        #expect(space.defaultBrowsingContainer == nil)
        #expect(tab.storeIdentifier == BrowserEngine.defaultStoreIdentifier)
    }

    /// Nobody loses logins: every space keeps the exact store identifier it used when
    /// the space itself was the container.
    @Test func migrationBindsEachSpaceToItsOldStore() throws {
        let (manager, containers, space) = try makeManagers()
        let other = manager.createContainer(name: "Second Space")
        let tab = try makeTab(manager, space, title: "one")
        let otherTab = try makeTab(manager, other, title: "two")
        let defaults = try scratchDefaults()

        ContainerManager.migrateSpaceStoresIfNeeded(context: manager.modelContext, defaults: defaults)

        let spaceDefault = try #require(space.defaultBrowsingContainer)
        let otherDefault = try #require(other.defaultBrowsingContainer)
        #expect(spaceDefault.storeIdentifier == space.id)
        #expect(otherDefault.storeIdentifier == other.id)
        #expect(spaceDefault.name == space.name)
        #expect(tab.browsingContainer?.id == spaceDefault.id)
        #expect(otherTab.browsingContainer?.id == otherDefault.id)
        #expect(tab.storeIdentifier == space.id)
        #expect(containers.containers.count >= 2)
    }

    @Test func migrationRunsOnlyOnce() throws {
        let (manager, containers, _) = try makeManagers()
        let defaults = try scratchDefaults()

        ContainerManager.migrateSpaceStoresIfNeeded(context: manager.modelContext, defaults: defaults)
        let afterFirst = containers.containers.count
        ContainerManager.migrateSpaceStoresIfNeeded(context: manager.modelContext, defaults: defaults)

        #expect(containers.containers.count == afterFirst)
    }

    @Test func renameRecolorAndReiconStick() throws {
        let (_, containers, _) = try makeManagers()
        let work = containers.create(name: "Work")

        containers.rename(work, to: "  Banking  ")
        containers.recolor(work, hex: BrowsingContainer.palette[3])
        containers.reicon(work, symbol: "dollarsign.circle.fill")

        #expect(work.name == "Banking")
        #expect(work.colorHex == BrowsingContainer.palette[3])
        #expect(work.iconSymbol == "dollarsign.circle.fill")

        // A blank name is a slip of the keyboard, not a rename.
        containers.rename(work, to: "   ")
        #expect(work.name == "Banking")
    }

    @Test func reorderRenumbersDensely() throws {
        let (_, containers, _) = try makeManagers()
        let first = containers.create(name: "One")
        let second = containers.create(name: "Two")
        let third = containers.create(name: "Three")

        containers.reorder([third, first, second])

        #expect(containers.containers.map(\.name) == ["Three", "One", "Two"])
        #expect(containers.containers.map(\.order) == [0, 1, 2])

        containers.move(third, to: 2)
        #expect(containers.containers.map(\.name) == ["One", "Two", "Three"])
    }

    @Test func firefoxIconNamesMapToSFSymbols() {
        #expect(BrowsingContainer.palette.count == 8)
        #expect(BrowsingContainer.palette.first == "#37ADFF")
        #expect(BrowsingContainer.iconSymbols["briefcase"] == "briefcase.fill")
        #expect(BrowsingContainer.icons.count == BrowsingContainer.iconSymbols.count)
        #expect(BrowsingContainer.icons.contains(BrowsingContainer.defaultIconSymbol))
    }

    /// Deletion used to walk the tabs through `move(_:to:)`, which saves and rebuilds a
    /// web view per tab. Every tab still has to end up in no container.
    @Test func deletingAContainerReassignsEveryTabAtOnce() throws {
        let (manager, containers, space) = try makeManagers()
        let work = containers.create(name: "Work")
        let tabs = try (0 ..< 3).map { try makeTab(manager, space, title: "tab\($0)") }
        for tab in tabs {
            containers.move(tab, to: work)
        }
        #expect(tabs.allSatisfy { $0.browsingContainer?.id == work.id })

        containers.delete(work)

        #expect(tabs.allSatisfy { $0.browsingContainer == nil })
        #expect(tabs.allSatisfy { $0.storeIdentifier == BrowserEngine.defaultStoreIdentifier })
        #expect(containers.containers.isEmpty)
        #expect(!manager.modelContext.hasChanges)
    }

    /// Lets one turn of the main queue run: `deleteContainer` finishes on a hop.
    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Window A deleting a space bulk-deletes its tabs. Window B was left rendering
    /// them, and its `activeContainer` pointed at a space that no longer existed.
    @Test func deletingASpaceInOneWindowMovesTheOtherWindowOffIt() async throws {
        let (windowA, _, space) = try makeManagers()
        let keeper = windowA.createContainer(name: "Keeper")
        let staying = try makeTab(windowA, keeper, title: "staying")
        let doomed = try makeTab(windowA, space, title: "doomed")
        try windowA.modelContext.save()

        let windowB = TabManager(
            modelContainer: windowA.modelContainer,
            modelContext: ModelContext(windowA.modelContainer),
            mediaController: MediaController()
        )
        let doomedInB = try #require(
            windowB.fetchContainers().flatMap(\.tabs).first { $0.id == doomed.id }
        )
        windowB.activateTab(doomedInB)
        #expect(windowB.activeContainer?.id == space.id)

        windowA.deleteContainer(space)
        await settle()
        await settle()

        #expect(windowB.activeTab?.id == staying.id)
        #expect(windowB.activeContainer?.id == keeper.id)
    }

    /// `containers` is a fetch, so a write used to change nothing `@Observable` could
    /// see and the settings list stayed stale until the user clicked away and back.
    @Test func aWriteInvalidatesObserversOfTheContainerList() throws {
        let (_, containers, _) = try makeManagers()
        var changed = false
        withObservationTracking {
            _ = containers.containers
        } onChange: {
            changed = true
        }

        let work = containers.create(name: "Work")
        #expect(changed)

        changed = false
        withObservationTracking {
            _ = containers.containers
        } onChange: {
            changed = true
        }
        containers.rename(work, to: "Work (personal)")
        #expect(changed)
    }
}
