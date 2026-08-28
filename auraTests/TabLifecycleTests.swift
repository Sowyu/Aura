import Foundation
@testable import Aura
import SwiftData
import Testing

/// Closing, reopening, duplicating and moving tabs: which row the selection falls to,
/// what comes back, and what a tab loses when it changes space.
@MainActor
struct TabLifecycleTests {
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
        return (manager, manager.createContainer(name: "Lifecycle Space"))
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
        // Both sides, like `addTab` does: setting only `Tab.container` leaves the
        // relationship array stale once anything re-fetches the space.
        space.tabs.append(tab)
        try manager.modelContext.save()
        return tab
    }

    /// `closeTab` deletes the row from a main-queue block, so anything asserting on the
    /// tab list has to let that block run first.
    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Closing

    @Test func closingTheActiveTabSelectsTheRowBelowIt() throws {
        let (manager, space) = try makeManager()
        let top = try makeTab(manager, space, order: 3)
        let middle = try makeTab(manager, space, order: 2)
        let bottom = try makeTab(manager, space, order: 1)
        manager.activateTab(middle)

        manager.closeTab(tab: middle)

        // The sidebar sorts descending, so "below" is the next lower order.
        #expect(manager.activeTab?.id == bottom.id)
        #expect(top.id != bottom.id)
    }

    @Test func closingTheBottomTabFallsBackUpwards() throws {
        let (manager, space) = try makeManager()
        let above = try makeTab(manager, space, order: 2)
        let bottom = try makeTab(manager, space, order: 1)
        manager.activateTab(bottom)

        manager.closeTab(tab: bottom)

        #expect(manager.activeTab?.id == above.id)
    }

    /// A hibernated tab has no web view. Requiring one here left the window on
    /// aura://home with a sidebar full of tabs.
    @Test func closingPicksAHibernatedNeighbour() throws {
        let (manager, space) = try makeManager()
        let neighbour = try makeTab(manager, space, order: 1)
        let active = try makeTab(manager, space, order: 2)
        manager.activateTab(active)
        neighbour.isWebViewReady = false

        manager.closeTab(tab: active)

        #expect(manager.activeTab?.id == neighbour.id)
    }

    @Test func closingInsideAFolderStaysInTheFolder() throws {
        let (manager, space) = try makeManager()
        let outside = try makeTab(manager, space, order: 9)
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        let upper = try makeTab(manager, space, order: 3)
        let lower = try makeTab(manager, space, order: 2)
        manager.move(tab: upper, to: folder)
        manager.move(tab: lower, to: folder)
        manager.activateTab(upper)

        manager.closeTab(tab: upper)

        #expect(manager.activeTab?.id == lower.id)
        #expect(manager.activeTab?.id != outside.id)
    }

    @Test func closingTheLastTabInAFolderLeavesTheFolder() throws {
        let (manager, space) = try makeManager()
        let outside = try makeTab(manager, space, order: 9)
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        let only = try makeTab(manager, space, order: 3)
        manager.move(tab: only, to: folder)
        manager.activateTab(only)

        manager.closeTab(tab: only)

        #expect(manager.activeTab?.id == outside.id)
    }

    @Test func closingTheActiveTabCanLandOnAPinnedTab() throws {
        let (manager, space) = try makeManager()
        let pinned = try makeTab(manager, space, order: 5, type: .pinned)
        let normal = try makeTab(manager, space, order: 1)
        manager.activateTab(normal)

        manager.closeTab(tab: normal)

        // No normal sibling is left, so the fallback is the space's other tab.
        #expect(manager.activeTab?.id == pinned.id)
    }

    /// No active tab is what puts `aura://home` back on screen; `BrowserSplitView`
    /// renders `HomePageView` whenever `activeTab` is nil.
    @Test func closingTheLastTabInASpaceClearsTheSelection() throws {
        let (manager, space) = try makeManager()
        let only = try makeTab(manager, space, order: 1)
        manager.activateTab(only)

        manager.closeTab(tab: only)

        #expect(manager.activeTab == nil)
    }

    // MARK: - Parking (pinned and favourite closes)

    /// Closing a pinned tab is not a removal: the row stays, reset to the URL it was
    /// pinned at, and the selection moves on.
    @Test func closingAPinnedTabParksItAtItsPinnedURL() async throws {
        let (manager, space) = try makeManager()
        let neighbour = try makeTab(manager, space, order: 1)
        let pinned = try makeTab(manager, space, order: 5, type: .pinned)
        let home = try #require(URL(string: "https://example.com/5"))
        pinned.savedURL = home
        pinned.updateURL(try #require(URL(string: "https://example.com/wandered?q=away")))
        manager.activateTab(pinned)

        manager.closeTab(tab: pinned)
        await settle()

        #expect(space.tabs.contains { $0.id == pinned.id })
        #expect(pinned.url == home)
        #expect(manager.activeTab?.id == neighbour.id)
        // Parking is not a close the user can undo, so it must not sit on the reopen stack.
        #expect(manager.recentlyClosedTabs.isEmpty)
    }

    @Test func closingAFavouriteTabParksItToo() async throws {
        let (manager, space) = try makeManager()
        let fav = try makeTab(manager, space, order: 2, type: .fav)
        fav.savedURL = fav.url
        manager.activateTab(fav)

        manager.closeTab(tab: fav)
        await settle()

        #expect(space.tabs.contains { $0.id == fav.id })
        #expect(manager.activeTab == nil)
    }

    /// The context menu's close is the deliberate one: it really removes the row.
    @Test func deleteTabRemovesAPinnedTabForReal() async throws {
        let (manager, space) = try makeManager()
        let pinned = try makeTab(manager, space, order: 2, type: .pinned)
        pinned.savedURL = pinned.url

        manager.deleteTab(tab: pinned)
        await settle()

        #expect(!space.tabs.contains { $0.id == pinned.id })
    }

    @Test func resetReturnsAWanderedPinnedTabAndDropsItsScroll() throws {
        let (manager, space) = try makeManager()
        let pinned = try makeTab(manager, space, order: 3, type: .pinned)
        let home = try #require(URL(string: "https://example.com/3"))
        pinned.savedURL = home
        pinned.updateURL(try #require(URL(string: "https://example.com/elsewhere")))
        pinned.hibernatedScrollOffset = CGPoint(x: 0, y: 400)
        #expect(pinned.hasLeftPinnedURL)

        manager.resetToPinnedURL(pinned)

        #expect(pinned.url == home)
        #expect(!pinned.hasLeftPinnedURL)
        #expect(pinned.hibernatedScrollOffset == nil)
    }

    @Test func replacePinnedURLAdoptsTheCurrentAddress() throws {
        let (manager, space) = try makeManager()
        let pinned = try makeTab(manager, space, order: 3, type: .pinned)
        pinned.savedURL = pinned.url
        let elsewhere = try #require(URL(string: "https://example.com/new-home"))
        pinned.updateURL(elsewhere)

        manager.replacePinnedURL(pinned)

        #expect(pinned.savedURL == elsewhere)
        #expect(!pinned.hasLeftPinnedURL)
    }

    /// Query and fragment churn on every search and in-page jump; only host and path
    /// say whether the tab left its pinned page.
    @Test func leavingThePinnedURLIsAHostAndPathQuestion() throws {
        let (manager, space) = try makeManager()
        let pinned = try makeTab(manager, space, order: 4, type: .pinned)
        pinned.savedURL = try #require(URL(string: "https://www.example.com/4"))

        pinned.updateURL(try #require(URL(string: "https://example.com/4?q=hello#top")))
        #expect(!pinned.hasLeftPinnedURL)

        pinned.updateURL(try #require(URL(string: "https://example.com/4/")))
        #expect(!pinned.hasLeftPinnedURL)

        pinned.updateURL(try #require(URL(string: "https://example.com/other")))
        #expect(pinned.hasLeftPinnedURL)

        pinned.updateURL(try #require(URL(string: "https://other.example.com/4")))
        #expect(pinned.hasLeftPinnedURL)
    }

    // MARK: - Reopening

    @Test func reopeningRestoresURLFolderAndPosition() async throws {
        let (manager, space) = try makeManager()
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        try makeTab(manager, space, order: 3)
        let closed = try makeTab(manager, space, order: 2)
        try makeTab(manager, space, order: 1)
        manager.move(tab: closed, to: folder)
        let closedURL = closed.url
        let closedOrder = closed.order

        manager.closeTab(tab: closed)
        await settle()
        #expect(!space.tabs.contains { $0.url == closedURL })

        manager.restoreLastTab()

        let restored = try #require(space.tabs.first { $0.url == closedURL })
        #expect(restored.folder?.id == folder.id)
        #expect(restored.order == closedOrder)
        #expect(manager.activeTab?.id == restored.id)
        #expect(Set(space.tabs.map(\.order)).count == space.tabs.count, "orders stay unique")
    }

    @Test func onlyTheLastFiveClosedTabsComeBack() async throws {
        let (manager, space) = try makeManager()
        for order in 1 ... 6 {
            try makeTab(manager, space, order: order)
        }
        for tab in Array(space.tabs) {
            manager.closeTab(tab: tab)
        }
        await settle()
        #expect(space.tabs.isEmpty)

        for _ in 0 ..< 8 {
            manager.restoreLastTab()
        }

        #expect(space.tabs.count == 5, "the recently closed list is capped at five")
    }

    // MARK: - Duplicating and moving

    @Test func duplicatingKeepsTheFolderAndWorksForInternalPages() throws {
        let (manager, space) = try makeManager()
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        let home = manager.addTab(container: space, isPrivate: false)
        manager.move(tab: home, to: folder)

        let copy = manager.duplicateTab(home)

        #expect(copy.url == home.url)
        #expect(copy.url.isOraHome)
        #expect(copy.folder?.id == folder.id, "the copy stays in the folder")
        #expect(copy.id != home.id)
        #expect(copy.browserPage == nil, "an internal page never gets a web view")
        #expect(Set(space.tabs.map(\.order)).count == space.tabs.count)
    }

    @Test func movingATabToAnotherSpaceDropsItsFolder() throws {
        let (manager, space) = try makeManager()
        let other = manager.createContainer(name: "Other")
        manager.activateContainer(space)
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        let staying = try makeTab(manager, space, order: 1)
        let moving = try makeTab(manager, space, order: 2)
        manager.move(tab: moving, to: folder)
        manager.activateTab(moving)

        manager.moveTabToContainer(moving, toContainer: other)

        #expect(moving.folder == nil, "folders belong to one space")
        #expect(moving.container.id == other.id)
        #expect(folder.sortedTabs.isEmpty)
        // The selection follows the space, not the tab that left it.
        #expect(manager.activeTab?.id == staying.id)
    }

    // MARK: - Activation

    @Test func activatingATabUpdatesTheLRUAndTheSpace() throws {
        let (manager, space) = try makeManager()
        let other = manager.createContainer(name: "Other")
        let tab = try makeTab(manager, space, order: 1)
        tab.lastAccessedAt = Date(timeIntervalSince1970: 0)
        manager.activateContainer(other)

        manager.activateTab(tab)

        #expect(manager.activeContainer?.id == space.id, "activating follows the tab into its space")
        #expect(try #require(tab.lastAccessedAt) > Date(timeIntervalSince1970: 1))
        #expect(tab.maybeIsActive)
    }

    /// Switching to a space whose tabs are all hibernated used to show aura://home.
    @Test func switchingSpacesSelectsTheMostRecentTabEvenWhenHibernated() throws {
        let (manager, space) = try makeManager()
        let other = manager.createContainer(name: "Other")
        let older = try makeTab(manager, space, order: 1)
        let newer = try makeTab(manager, space, order: 2)
        older.lastAccessedAt = Date(timeIntervalSince1970: 1000)
        newer.lastAccessedAt = Date(timeIntervalSince1970: 2000)
        older.isWebViewReady = false
        newer.isWebViewReady = false
        manager.activateContainer(other)

        manager.activateContainer(space)

        #expect(manager.activeTab?.id == newer.id)
    }

    @Test func switchingToAnEmptySpaceClearsTheSelection() throws {
        let (manager, space) = try makeManager()
        let empty = manager.createContainer(name: "Empty")
        let tab = try makeTab(manager, space, order: 1)
        manager.activateTab(tab)

        manager.activateContainer(empty)

        #expect(manager.activeTab == nil)
        #expect(tab.maybeIsActive == false)
    }

    // MARK: - URL mirror

    @Test func theSearchableURLMirrorFollowsNavigation() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, order: 1)

        let target = try #require(URL(string: "https://example.org/deep/link?q=1"))
        tab.updateURL(target)

        #expect(tab.url == target)
        #expect(tab.urlString == target.absoluteString, "tab search reads urlString, not url")
        #expect(manager.search("deep/link").map(\.id) == [tab.id])
    }

    // MARK: - Launch policy

    @Test func launchPolicyDropsNormalTabsOnceAndKeepsPinned() async throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previous = store.restoreTabsOnLaunch
        let pinned = try makeTab(manager, space, order: 3, type: .pinned)
        let dropped = try makeTab(manager, space, order: 2)
        try manager.modelContext.save()

        // No `await` until the process-wide flags are back: another test running on the
        // main actor would otherwise launch into this one's policy.
        store.restoreTabsOnLaunch = false
        TabManager.didApplyLaunchPolicy = false
        _ = TabManager(
            modelContainer: manager.modelContainer,
            modelContext: manager.modelContext,
            mediaController: MediaController()
        )
        let secondWindowTab = try makeTab(manager, space, order: 1)
        _ = TabManager(
            modelContainer: manager.modelContainer,
            modelContext: manager.modelContext,
            mediaController: MediaController()
        )
        TabManager.didApplyLaunchPolicy = true
        store.restoreTabsOnLaunch = previous

        await settle()
        // Straight from the store: a relationship array read across two managers can
        // hand back a stale snapshot.
        let surviving = try manager.modelContext.fetch(FetchDescriptor<Tab>()).map(\.id)
        #expect(surviving.contains(pinned.id), "pinned tabs always come back")
        #expect(!surviving.contains(dropped.id), "saved normal tabs are dropped")
        #expect(surviving.contains(secondWindowTab.id), "the policy runs once per launch")
    }

    /// A private window opening before the first normal one must not spend the
    /// once-per-launch flag against its own empty in-memory store.
    @Test func launchPolicyBelongsToTheOnDiskStore() {
        #expect(TabManager.ownsLaunchPolicy(isInMemoryStore: false, isTestHost: false))
        #expect(!TabManager.ownsLaunchPolicy(isInMemoryStore: true, isTestHost: false))
        // Every manager built here runs in memory, so the replay above still gets a turn.
        #expect(TabManager.ownsLaunchPolicy(isInMemoryStore: true, isTestHost: true))
    }

    /// Pinned and favourite tabs reopen at the URL they were pinned at. Every other tab,
    /// including one coming back from hibernation mid-session, reopens where it was.
    @Test func pinnedTabsReopenAtTheirSavedURL() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, order: 1)
        let pinnedAt = tab.url

        manager.togglePinTab(tab)
        let wandered = try #require(URL(string: "https://example.com/deep/page"))
        tab.updateURL(wandered)

        #expect(tab.savedURL == pinnedAt)
        #expect(tab.launchURL == pinnedAt, "a relaunch puts a pinned tab back on its own page")

        manager.togglePinTab(tab)
        #expect(tab.savedURL == nil)
        #expect(tab.launchURL == wandered)
    }

    /// Private windows get an in-memory store, so nothing they open reaches the disk.
    @Test func privateWindowsUseAnInMemoryStore() {
        #expect(ModelConfiguration.oraDatabase(isPrivate: true).isStoredInMemoryOnly)
        #expect(ModelConfiguration.oraDatabase(isPrivate: false).isStoredInMemoryOnly == false)
    }

    /// A store that refuses to open used to be deleted, taking every tab, space and
    /// history row with it. One retry, then stop, and the file stays either way.
    @Test func aFailedStoreOpenRetriesOnceAndKeepsTheFile() {
        #expect(StoreOpenFailure.action(for: 0) == .retry)
        #expect(StoreOpenFailure.action(for: 1) == .giveUp)
        #expect(StoreOpenFailure.action(for: 5) == .giveUp)
    }

    // MARK: - Closing without a web view

    /// The row used to go only after `stopMedia`'s two web-process round trips, so a
    /// tab that never loaded sat in the sidebar until the next main-queue turn.
    @Test func closingATabWithNoWebViewDeletesTheRowImmediately() throws {
        let (manager, space) = try makeManager()
        try makeTab(manager, space, order: 2)
        let closing = try makeTab(manager, space, order: 1)
        let closingID = closing.id

        manager.closeTab(tab: closing)

        // No `settle()` here on purpose: the delete is part of the call.
        #expect(!space.tabs.contains { $0.id == closingID })
    }

    // MARK: - Duplicating

    @Test func duplicatingAPinnedTabKeepsItPinnedAndLandsNextToIt() throws {
        let (manager, space) = try makeManager()
        try makeTab(manager, space, order: 3, type: .pinned)
        let original = try makeTab(manager, space, order: 2, type: .pinned)
        try makeTab(manager, space, order: 1, type: .pinned)

        let copy = manager.duplicateTab(original)

        #expect(copy.type == .pinned, "a copy of a pinned tab is pinned")
        let pinned = space.tabs.filter { $0.type == .pinned }.sorted { $0.order > $1.order }
        let copyIndex = try #require(pinned.firstIndex { $0.id == copy.id })
        let originalIndex = try #require(pinned.firstIndex { $0.id == original.id })
        #expect(abs(copyIndex - originalIndex) == 1, "the copy sits next to the original")
        #expect(Set(pinned.map(\.order)).count == pinned.count, "no duplicate orders")
    }

    // MARK: - Opening

    /// `openTab` was wrapped in `if let host = url.host` and handed back nil for every
    /// aura:// address, so `.openURL` on an internal page opened nothing at all.
    @Test func openTabOpensInternalPages() throws {
        let (manager, space) = try makeManager()
        let historyManager = HistoryManager(
            modelContainer: manager.modelContainer,
            modelContext: manager.modelContext
        )

        let tab = try #require(manager.openTab(
            url: .oraSettings(section: nil),
            historyManager: historyManager,
            isPrivate: false
        ))

        #expect(tab.url.isOraSettings)
        #expect(tab.browserPage == nil, "an internal page never gets a web view")
        #expect(space.tabs.contains { $0.id == tab.id })
        #expect(manager.activeTab?.id == tab.id)
    }

    /// `.urlQueryAllowed` leaves &, + and # alone, so a search for "a&b" arrived at the
    /// engine as two parameters and everything after # never left the browser.
    @Test func theSearchFallbackEscapesQueryDelimiters() throws {
        let encoded = try #require("a&b+c#d".addingPercentEncoding(withAllowedCharacters: .searchQueryAllowed))

        #expect(encoded == "a%26b%2Bc%23d")
        let url = try #require(URL(string: "https://www.google.com/search?q=" + encoded))
        #expect(url.fragment == nil, "the # stays inside the query")
    }

    /// The getter deleted legacy files and re-stat'd the directory on every favicon
    /// write; now it resolves once per process.
    @Test func theFaviconDirectoryIsResolvedOnce() {
        let directory = FileManager.default.faviconDirectory

        #expect(directory == FileManager.faviconDirectory, "the instance accessor is the static one")
        #expect(directory.lastPathComponent == "v3")
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Cross-window deletes

    /// A second window over the same store, built the way `OraRoot` builds one: its own
    /// `ModelContext`, its own manager, the one shared container.
    private func makeSecondWindow(_ first: TabManager) -> TabManager {
        TabManager(
            modelContainer: first.modelContainer,
            modelContext: ModelContext(first.modelContainer),
            mediaController: MediaController()
        )
    }

    /// Window A closing a tab that window B is showing. B used to keep rendering the
    /// deleted row, and its id kept exempting the ghost from hibernation.
    @Test func closingATabInOneWindowReselectsInTheOther() async throws {
        let (windowA, space) = try makeManager()
        let doomed = try makeTab(windowA, space, order: 2)
        let survivor = try makeTab(windowA, space, order: 1)

        let windowB = makeSecondWindow(windowA)
        let spaceInB = try #require(windowB.fetchContainers().first { $0.id == space.id })
        let doomedInB = try #require(spaceInB.tabs.first { $0.id == doomed.id })
        windowB.activateTab(doomedInB)
        windowB.hibernating.insert(doomed.id)
        windowB.trackRecentlyClosedTab(doomedInB)

        windowA.closeTab(tab: doomed)
        await settle()

        #expect(windowB.activeTab?.id == survivor.id, "window B kept a deleted row selected")
        #expect(!windowB.hibernating.contains(doomed.id))
        #expect(!windowB.recentlyClosedTabs.contains { $0.id == doomed.id })
        #expect(!TabManager.activeTabIDsAcrossWindows.contains(doomed.id))
    }

    /// The same close replayed from the other side: the window that did the closing
    /// keeps the selection it picked itself.
    @Test func theClosingWindowKeepsItsOwnReselection() async throws {
        let (windowA, space) = try makeManager()
        let doomed = try makeTab(windowA, space, order: 2)
        let survivor = try makeTab(windowA, space, order: 1)
        _ = makeSecondWindow(windowA)
        windowA.activateTab(doomed)

        windowA.closeTab(tab: doomed)
        await settle()

        #expect(windowA.activeTab?.id == survivor.id)
    }

    /// The reconcile reads the active tab's position from this copy, never from the
    /// model, because the model's row may already be gone when the notification lands.
    @Test func activationCopiesTheTabPosition() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, order: 3)

        manager.activateTab(tab)
        let position = try #require(manager.activePosition)
        #expect(position.id == tab.id)
        #expect(position.containerID == space.id)
        #expect(position.order == 3)

        manager.activeTab = nil
        #expect(manager.activePosition == nil)
    }

    /// WebKit tracks open tabs by adapter object. A space deletion bulk-deletes its tabs
    /// without ever reaching `closeTab`, so the adapters used to outlive the rows.
    @Test func deletingASpaceDiscardsItsExtensionAdapters() async throws {
        guard #available(macOS 15.4, *) else { return }
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, order: 1)
        let tabID = tab.id
        _ = ExtensionTabAdapter.adapter(for: tab)
        #expect(ExtensionTabAdapter.cachedAdapter(for: tabID) != nil)

        manager.deleteContainer(space)
        await settle()
        await settle()

        #expect(ExtensionTabAdapter.cachedAdapter(for: tabID) == nil)
    }
}

/// Drag-reorder invariants: the sidebar sorts on `order` descending, so every row in a
/// section needs its own value and moving one row must not renumber the rest.
@MainActor
struct TabOrderingTests {
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
        return (manager, manager.createContainer(name: "Ordering Space"))
    }

    @discardableResult
    private func makeTab(_ manager: TabManager, _ space: TabContainer, order: Int, type: TabType = .normal) throws
        -> Tab {
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
        // Both sides, like `addTab` does: setting only `Tab.container` leaves the
        // relationship array stale once anything re-fetches the space.
        space.tabs.append(tab)
        try manager.modelContext.save()
        return tab
    }

    @Test func draggingIntoAFolderKeepsOrdersUniqueAndDescending() throws {
        let (manager, space) = try makeManager()
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        let inFolderTop = try makeTab(manager, space, order: 4)
        let inFolderBottom = try makeTab(manager, space, order: 3)
        manager.move(tab: inFolderTop, to: folder)
        manager.move(tab: inFolderBottom, to: folder)
        let outsider = try makeTab(manager, space, order: 1)

        // What `TabDropDelegate` does: join the target's folder, then reorder next to it.
        outsider.folder = folder
        space.reorderTabs(from: outsider, to: inFolderTop)

        let orders = folder.sortedTabs.map(\.order)
        #expect(folder.sortedTabs.map(\.id) == [outsider.id, inFolderTop.id, inFolderBottom.id])
        #expect(Set(orders).count == orders.count, "no duplicate orders")
        #expect(orders == orders.sorted(by: >), "the folder stays monotonic")
    }

    @Test func draggingOutOfAFolderKeepsOrdersUnique() throws {
        let (manager, space) = try makeManager()
        let folder = try #require(manager.createFolder(name: "Work", in: space))
        let child = try makeTab(manager, space, order: 4)
        manager.move(tab: child, to: folder)
        let topLevelUpper = try makeTab(manager, space, order: 2)
        let topLevelLower = try makeTab(manager, space, order: 1)

        child.folder = nil
        space.reorderTabs(from: child, to: topLevelLower)

        let topLevel = space.tabs.filter { $0.folder == nil }.sorted { $0.order > $1.order }
        #expect(topLevel.map(\.id) == [topLevelUpper.id, topLevelLower.id, child.id])
        #expect(Set(space.tabs.map(\.order)).count == space.tabs.count)
    }

    /// The old swap-chain walked past the end of its array when the two tabs shared an
    /// order, which duplicate orders in an imported store made reachable.
    @Test func reorderingTabsWithTheSameOrderIsSafe() throws {
        let (manager, space) = try makeManager()
        let first = try makeTab(manager, space, order: 2)
        let second = try makeTab(manager, space, order: 2)

        space.reorderTabs(from: first, to: second)

        // Nothing to renumber, and above all nothing that walks off the end of the array.
        #expect(space.tabs.count == 2)
        #expect(first.order == 2)
        #expect(second.order == 2)
    }

    @Test func reorderingIgnoresTabsFromAnotherSection() throws {
        let (manager, space) = try makeManager()
        let pinned = try makeTab(manager, space, order: 5, type: .pinned)
        let normal = try makeTab(manager, space, order: 1)

        space.reorderTabs(from: normal, to: pinned)

        #expect(normal.order == 1, "a normal tab does not join the pinned section by drag alone")
        #expect(pinned.order == 5)
    }

    @Test func aNewTabNeverTakesAFolderOrder() throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previous = store.newTabPosition
        defer { store.newTabPosition = previous }
        store.newTabPosition = .top
        try makeTab(manager, space, order: 1)
        let folder = try #require(manager.createFolder(name: "Work", in: space))

        let fresh = manager.addTab(container: space, isPrivate: false)

        #expect(fresh.order > folder.order, "a new tab lands above every existing row")
    }

    @Test func foldersReorderAmongThemselves() throws {
        let (manager, space) = try makeManager()
        let first = try #require(manager.createFolder(name: "One", in: space))
        let second = try #require(manager.createFolder(name: "Two", in: space))
        let third = try #require(manager.createFolder(name: "Three", in: space))
        let ordersBefore = Set(space.folders.map(\.order))

        // Drag the top folder onto the bottom one.
        manager.move(folder: third, to: first)

        let sorted = space.folders.sorted { $0.order > $1.order }
        #expect(sorted.map(\.id) == [second.id, first.id, third.id])
        #expect(Set(space.folders.map(\.order)) == ordersBefore, "the slots are reused, not invented")
    }

    @Test func aFolderDoesNotMoveIntoAnotherSpace() throws {
        let (manager, space) = try makeManager()
        let other = manager.createContainer(name: "Other")
        let here = try #require(manager.createFolder(name: "Here", in: space))
        let there = try #require(manager.createFolder(name: "There", in: other))
        let orderBefore = here.order

        manager.move(folder: here, to: there)

        #expect(here.order == orderBefore)
        #expect(here.container.id == space.id)
    }
}
