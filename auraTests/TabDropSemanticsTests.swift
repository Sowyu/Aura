import Foundation
@testable import Aura
import SwiftData
import Testing

/// What a released drag does to the tab it carried: which tier it lands in, and what
/// happens to the URL it was pinned at on the way. The position half lives in
/// `TabDropResolverTests`; this is the commit half.
@MainActor
struct TabDropSemanticsTests {
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
        return (manager, manager.createContainer(name: "Drop Space"))
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

    private func drop(
        _ tab: Tab,
        between target: Tab,
        zone: TabDragZone,
        manager: TabManager,
        space: TabContainer
    ) {
        TabDropCommit.apply(
            PendingTabDrop(
                draggedID: tab.id,
                zone: zone,
                target: .between(TabDropIndicator(targetID: target.id, below: false))
            ),
            in: space,
            tabManager: manager
        )
    }

    // MARK: - Promotion and demotion

    @Test func droppingANormalTabBetweenFavouritesPromotesIt() throws {
        let (manager, space) = try makeManager()
        let fav = try makeTab(manager, space, order: 9, type: .fav)
        fav.savedURL = fav.url
        let normal = try makeTab(manager, space, order: 1)

        drop(normal, between: fav, zone: .fav(space.id), manager: manager, space: space)

        #expect(normal.type == .fav)
        // A normal tab adopts its current address as the one it was pinned at.
        #expect(normal.savedURL == normal.url)
    }

    /// The Zen rule: moving between the pinned tiers never re-pins the detour. A pinned
    /// tab that wandered off and is then promoted keeps the URL it was pinned at.
    @Test func promotingAWanderedPinnedTabKeepsItsPinnedURL() throws {
        let (manager, space) = try makeManager()
        let fav = try makeTab(manager, space, order: 9, type: .fav)
        fav.savedURL = fav.url
        let pinned = try makeTab(manager, space, order: 5, type: .pinned)
        let home = try #require(URL(string: "https://example.com/5"))
        pinned.savedURL = home
        pinned.updateURL(try #require(URL(string: "https://example.com/wandered")))

        drop(pinned, between: fav, zone: .fav(space.id), manager: manager, space: space)

        #expect(pinned.type == .fav)
        #expect(pinned.savedURL == home)
    }

    @Test func demotingAFavouriteToPinnedKeepsItsPinnedURL() throws {
        let (manager, space) = try makeManager()
        let pinned = try makeTab(manager, space, order: 9, type: .pinned)
        pinned.savedURL = pinned.url
        let fav = try makeTab(manager, space, order: 5, type: .fav)
        let home = try #require(URL(string: "https://example.com/5"))
        fav.savedURL = home
        fav.updateURL(try #require(URL(string: "https://example.com/wandered")))

        drop(fav, between: pinned, zone: .pinned(space.id), manager: manager, space: space)

        #expect(fav.type == .pinned)
        #expect(fav.savedURL == home)
    }

    @Test func demotingToNormalUnpins() throws {
        let (manager, space) = try makeManager()
        let normal = try makeTab(manager, space, order: 9)
        let pinned = try makeTab(manager, space, order: 5, type: .pinned)
        pinned.savedURL = pinned.url

        drop(pinned, between: normal, zone: .normal(space.id), manager: manager, space: space)

        #expect(pinned.type == .normal)
        #expect(pinned.savedURL == nil)
    }

    /// An empty section has no row to line up against; the drop still changes tier and
    /// the same pinned-URL rule applies.
    @Test func droppingIntoAnEmptyFavouritesGridPromotesToTheTop() throws {
        let (manager, space) = try makeManager()
        let below = try makeTab(manager, space, order: 3)
        let pinned = try makeTab(manager, space, order: 1, type: .pinned)
        let home = try #require(URL(string: "https://example.com/1"))
        pinned.savedURL = home
        pinned.updateURL(try #require(URL(string: "https://example.com/wandered")))

        TabDropCommit.apply(
            PendingTabDrop(draggedID: pinned.id, zone: .fav(space.id), target: .emptySection),
            in: space,
            tabManager: manager
        )

        #expect(pinned.type == .fav)
        #expect(pinned.savedURL == home)
        #expect(pinned.order > below.order)
    }

    /// Folders reorder against folders; the pinned tiers cannot take one, so the drop
    /// falls on the floor rather than retyping anything.
    @Test func aFolderDroppedOnTheFavouritesGridDoesNothing() throws {
        let (manager, space) = try makeManager()
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        let tab = try makeTab(manager, space, order: 1)
        manager.move(tab: tab, to: folder)

        TabDropCommit.apply(
            PendingTabDrop(draggedID: folder.id, zone: .fav(space.id), target: .emptySection),
            in: space,
            tabManager: manager
        )

        #expect(space.folders.contains { $0.id == folder.id })
        #expect(tab.type == .normal)
        #expect(tab.folder?.id == folder.id)
    }

    // MARK: - The same rule outside a drag

    @Test func togglingFavoriteOnAPinnedTabKeepsThePinnedURL() throws {
        let (manager, space) = try makeManager()
        let pinned = try makeTab(manager, space, order: 2, type: .pinned)
        let home = try #require(URL(string: "https://example.com/2"))
        pinned.savedURL = home
        pinned.updateURL(try #require(URL(string: "https://example.com/wandered")))

        manager.toggleFavTab(pinned)

        #expect(pinned.type == .fav)
        #expect(pinned.savedURL == home)
    }

    @Test func rePinningANormalTabAdoptsItsCurrentAddress() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, order: 2, type: .pinned)
        tab.savedURL = tab.url

        manager.togglePinTab(tab)
        #expect(tab.savedURL == nil)

        let elsewhere = try #require(URL(string: "https://example.com/elsewhere"))
        tab.updateURL(elsewhere)
        manager.togglePinTab(tab)

        #expect(tab.type == .pinned)
        #expect(tab.savedURL == elsewhere)
    }
}
