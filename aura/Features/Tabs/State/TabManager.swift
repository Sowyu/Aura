import os.log
import SwiftData
import SwiftUI

/// Every save in the tab layer goes through here. `try?` swallowed the error, so a
/// dropped write only showed up later as a tab or a space that came back wrong.
@MainActor
func saveOrLog(_ context: ModelContext, function: StaticString = #function) {
    do {
        try context.save()
    } catch {
        let reason = error.localizedDescription
        AuraLog.category("Tabs").error(
            "Saving the tab store failed in \(String(describing: function), privacy: .public): \(reason, privacy: .public)"
        )
    }
}

// MARK: - Tab Manager

/// Weak box for the cross-window manager registry.
@MainActor
private final class WeakTabManager {
    weak var value: TabManager?
    init(value: TabManager) { self.value = value }
}

@Observable
@MainActor
// swiftlint:disable:next type_body_length
final class TabManager {
    var activeContainer: TabContainer?
    var activeTab: Tab?
    /// Sidebar folder currently showing its inline rename field, if any.
    var renamingFolderID: UUID?
    let modelContainer: ModelContainer
    let modelContext: ModelContext
    let mediaController: MediaController
    /// Saved back/forward lists and scroll offsets for this window's tabs.
    @ObservationIgnored let sessionStore: TabSessionStore
    /// True while the previous run's tabs are on screen and the launch policy that would
    /// drop them is held back waiting for the user to answer the restore bar.
    var offersSessionRestore = false

    /// Note: Could be made injectable via init parameter if preferred
    let tabSearchingService: TabSearchingProviding

    /// Every window builds its own `TabManager` over the same store, so "is this tab
    /// active?" is a question about the whole app, not about one manager. Weak on
    /// purpose: a closed window's manager drops out on its own.
    @ObservationIgnored private static var registry: [WeakTabManager] = []

    // ponytail: a manager only leaves the registry when it deallocates, and `Tab` holds
    // its manager strongly, so a closed window's last active tab stays warm. Unregister
    // explicitly if closing windows is ever shown to hold memory.
    /// Ids of the tabs shown in any open window. Hibernation consults this instead of
    /// its own `activeTab`, so a tab on screen in another window is never evicted.
    static var activeTabIDsAcrossWindows: Set<UUID> {
        registry.removeAll { $0.value == nil }
        return Set(registry.compactMap { $0.value?.activeTab?.id })
    }

    /// One last look at every live tab before the process goes, from
    /// `applicationWillTerminate`. Only the synchronous half of a capture: a scroll probe
    /// is a round trip to the web process and there is no turn of the run loop left to
    /// answer on. The periodic pass is what keeps the offset close to current.
    static func captureLiveSessions() {
        registry.removeAll { $0.value == nil }
        for manager in registry.compactMap(\.value) {
            manager.captureOwnLiveSessions()
        }
    }

    /// Newest tabs first and capped, so quitting with a hundred live tabs is not a
    /// hundred blob writes between the user's ⌘Q and the app going away.
    private func captureOwnLiveSessions() {
        let live = fetchContainers()
            .flatMap(\.tabs)
            .filter { $0.isWebViewReady && !$0.isPrivate }
            .sorted { ($0.lastAccessedAt ?? .distantPast) > ($1.lastAccessedAt ?? .distantPast) }
            .prefix(TabSessionStore.maxSessions)
        var changed = false
        for tab in live where sessionStore.capture(tab) { changed = true }
        if changed { sessionStore.save() }
    }

    @ObservationIgnored private var cleanupTimer: Timer?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var deletionObserver: NSObjectProtocol?
    /// Last live-tab cap this manager acted on, so a change to any other setting does
    /// not trigger an eviction pass.
    @ObservationIgnored private var appliedMaxLiveTabs: Int
    /// Tabs with an unsaved-input probe in flight. A second maintenance pass must not
    /// ask the same page again while the first answer is still on its way back.
    /// Internal only because `TabManager+Hibernation` needs it.
    @ObservationIgnored var hibernating: Set<UUID> = []
    /// Reopen stack, newest last. Lives here because an extension cannot add
    /// stored properties; the behaviour is in `TabManager+RecentlyClosed`.
    @ObservationIgnored var recentlyClosedTabs: [ClosedTabSnapshot] = []
    let maxRecentlyClosedTabs = 5

    init(
        modelContainer: ModelContainer,
        modelContext: ModelContext,
        mediaController: MediaController,
        tabSearchingService: TabSearchingProviding = TabSearchingService()
    ) {
        self.modelContainer = modelContainer
        self.modelContext = modelContext
        self.mediaController = mediaController
        self.tabSearchingService = tabSearchingService
        self.appliedMaxLiveTabs = SettingsStore.shared.maxLiveTabs
        self.sessionStore = TabSessionStore(modelContext: modelContext)

        self.modelContext.undoManager = UndoManager()
        Self.registry.append(WeakTabManager(value: self))
        observeCrossWindowDeletes()
        applyLaunchTabPolicy()
        initializeActiveContainerAndTab()

        // Start automatic cleanup timer (every minute)
        startCleanupTimer()
        observeLiveTabLimitChanges()
        // Pressure can arrive in the first minute, before the maintenance tick.
        hibernationPolicy.arm()
    }

    /// The cap is a stored default, so lowering it in Settings has to bite now rather
    /// than at the next minute tick.
    private func observeLiveTabLimitChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `OperationQueue.main` is not the main actor's executor, so this hops
            // rather than asserting its way onto it.
            Task { @MainActor in
                guard let self else { return }
                let limit = SettingsStore.shared.maxLiveTabs
                guard limit != self.appliedMaxLiveTabs else { return }
                self.appliedMaxLiveTabs = limit
                self.enforceLiveTabLimit()
            }
        }
    }

    /// Another window deleting a tab is invisible here until it says so: each window
    /// holds its own `ModelContext`, so this manager can be rendering a row that is no
    /// longer in the store and exempting it from hibernation on top of that.
    ///
    /// `queue: nil` on purpose. Every poster is this same main-actor class, so the
    /// reconcile runs inline and the deleting window cannot return before the other
    /// windows have let go of the row.
    private func observeCrossWindowDeletes() {
        deletionObserver = NotificationCenter.default.addObserver(
            forName: .tabsDeleted,
            object: nil,
            queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? TabManager) !== self else { return }
                guard let ids = note.userInfo?["ids"] as? [UUID], !ids.isEmpty else { return }
                self.reconcileDeletedTabs(Set(ids))
            }
        }
    }

    /// Tells the other windows which rows just went. Called after the save, so a window
    /// that reconciles by re-fetching sees the store the notification describes.
    func announceDeletedTabs(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        NotificationCenter.default.post(name: .tabsDeleted, object: self, userInfo: ["ids": ids])
    }

    // MARK: - Public API's

    func search(_ text: String) -> [Tab] {
        tabSearchingService.search(
            text,
            activeContainer: activeContainer,
            modelContext: modelContext
        )
    }

    func openFromEngine(
        engineName: SearchEngineID,
        query: String,
        historyManager: HistoryManager,
        isPrivate: Bool
    ) {
        if let url = SearchEngineService().getSearchURLForEngine(
            engineName: engineName,
            query: query
        ) {
            openTab(url: url, historyManager: historyManager, isPrivate: isPrivate)
        }
    }

    func isActive(_ tab: Tab) -> Bool {
        if let activeTab = self.activeTab {
            return activeTab.id == tab.id
        }
        return false
    }

    func togglePinTab(_ tab: Tab) {
        if tab.type == .pinned {
            tab.type = .normal
            tab.savedURL = nil
        } else {
            tab.type = .pinned
            tab.savedURL = tab.url
            // Only normal tabs live in folders.
            tab.folder = nil
        }

        saveOrLog(modelContext)
    }

    func toggleFavTab(_ tab: Tab) {
        if tab.type == .fav {
            tab.type = .normal
            tab.savedURL = nil
        } else {
            tab.type = .fav
            tab.savedURL = tab.url
            tab.folder = nil
        }

        saveOrLog(modelContext)
    }

    // MARK: - Container Public API's

    /// Folders belong to one space, so a tab that leaves its space leaves its folder,
    /// and it takes a fresh `order` so it cannot collide with a row already there.
    func moveTabToContainer(_ tab: Tab, toContainer: TabContainer) {
        guard tab.container.id != toContainer.id else { return }
        let wasActive = activeTab?.id == tab.id
        let replacement = wasActive ? neighbour(after: tab) : nil

        tab.folder = nil
        tab.order = nextTabOrder(in: toContainer)
        tab.container = toContainer
        // A tab already assigned to a container keeps it; only an uncontained tab picks
        // up the new space's default.
        if tab.browsingContainer == nil {
            tab.browsingContainer = toContainer.defaultBrowsingContainer
        }

        // The moved tab is no longer in this window's space, so the selection follows
        // the space, not the tab.
        if wasActive {
            if let replacement {
                activateTab(replacement)
            } else {
                activeTab?.maybeIsActive = false
                activeTab = nil
            }
        }
        saveOrLog(modelContext)
    }

    private func initializeActiveContainerAndTab() {
        // Ensure containers are fetched
        let containers = fetchContainers()

        // Get the last accessed container
        if let lastAccessedContainer = containers.first {
            activeContainer = lastAccessedContainer
            // Get the last accessed tab from the active container
            if let lastAccessedTab = lastAccessedContainer.tabs
                .sorted(by: { ($0.lastAccessedAt ?? Date.distantPast) > ($1.lastAccessedAt ?? Date.distantPast) })
                .first
            {
                activeTab = lastAccessedTab
                activeTab?.maybeIsActive = true
            }
        } else {
            let newContainer = createContainer()
            activeContainer = newContainer
        }
    }

    @discardableResult
    func createContainer(
        name: String = "Default",
        emoji: String = "•",
        iconSymbol: String? = nil,
        iconColorHex: String? = nil
    ) -> TabContainer {
        let newContainer = TabContainer(
            name: name,
            emoji: emoji,
            iconSymbol: iconSymbol,
            iconColorHex: iconColorHex,
            order: nextContainerOrder()
        )
        modelContext.insert(newContainer)
        activeContainer = newContainer
        activeTab?.maybeIsActive = false
        activeTab = nil
        saveOrLog(modelContext)
        return newContainer
    }

    func renameContainer(
        _ container: TabContainer,
        name: String,
        emoji: String,
        iconSymbol: String? = nil,
        iconColorHex: String? = nil
    ) {
        container.name = name
        container.emoji = emoji
        container.iconSymbol = iconSymbol
        container.iconColorHex = iconColorHex
        saveOrLog(modelContext)
    }

    func deleteContainer(_ container: TabContainer) {
        let containerId = container.id
        Task { @MainActor in
            do {
                try PasswordManagerService.shared.deleteEntries(for: containerId)
            } catch {
                // A keychain failure must not abort the container deletion;
                // surface it and keep going so the space is still removed.
                ToastManager.shared.show(
                    "Couldn't delete saved passwords for this space",
                    icon: .system("exclamationmark.triangle")
                )
            }

            // Website data lives in browsing containers now and outlives the space;
            // deleting the container is what clears it.

            guard let persistedContainer = fetchContainer(id: containerId) else {
                SettingsStore.shared.removeContainerSettings(for: containerId)
                return
            }

            let wasActiveContainer = activeContainer?.id == containerId
            prepareForContainerDeletion(isActiveContainer: wasActiveContainer)
            let deletedTabIDs = deleteContainerContents(persistedContainer, containerId: containerId)

            // Save child deletions before deleting the container.
            // In practice, SwiftData can fail when the parent and children are
            // removed in the same save pass while non-optional inverse
            // relationships still exist.
            saveOrLog(modelContext)

            guard let containerToDelete = fetchContainer(id: containerId) else {
                SettingsStore.shared.removeContainerSettings(for: containerId)
                activateFallbackContainerIfNeeded(afterDeletingActiveContainer: wasActiveContainer)
                announceDeletedTabs(deletedTabIDs)
                return
            }

            modelContext.delete(containerToDelete)
            saveOrLog(modelContext)
            SettingsStore.shared.removeContainerSettings(for: containerId)

            activateFallbackContainerIfNeeded(afterDeletingActiveContainer: wasActiveContainer)
            announceDeletedTabs(deletedTabIDs)
        }
    }

    /// Switching spaces selects the space's most recently used tab. Hibernated tabs are
    /// eligible: requiring a live web view here left a space full of unloaded tabs
    /// showing aura://home instead of the tab the user last had open.
    func activateContainer(_ container: TabContainer) {
        activeContainer = container
        container.lastAccessedAt = Date()

        if let lastAccessedTab = container.tabs
            .sorted(by: { ($0.lastAccessedAt ?? .distantPast) > ($1.lastAccessedAt ?? .distantPast) })
            .first
        {
            activateTab(lastAccessedTab)
        } else {
            activeTab?.maybeIsActive = false
            activeTab = nil
        }

        saveOrLog(modelContext)
    }

    // MARK: - Tab Public API's

    /// The sidebar sorts by `order` descending, so the top of the list is the highest
    /// order and the bottom is one below the lowest.
    func nextTabOrder(in container: TabContainer) -> Int {
        // Folders sit on the same scale as top-level tabs, so ignoring them here handed
        // a new tab the order a folder already had.
        let orders = container.tabs.map(\.order) + container.folders.map(\.order)
        switch SettingsStore.shared.newTabPosition {
        case .top: return (orders.max() ?? 0) + 1
        case .bottom: return (orders.min() ?? 1) - 1
        }
    }

    func addTab(
        title: String = "Untitled",
        url: URL = .oraHome,
        container: TabContainer,
        favicon: URL? = nil,
        historyManager: HistoryManager? = nil,
        downloadManager: DownloadManager? = nil,
        isPrivate: Bool,
        activateAfterAdding: Bool = true
    ) -> Tab {
        let cleanHost: String? = {
            guard let host = url.host else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }()
        let newTab = Tab(
            url: url,
            title: url.isOraHome ? "New Tab" : (cleanHost ?? "New Tab"),
            favicon: favicon,
            container: container,
            type: .normal,
            isPlayingMedia: false,
            order: nextTabOrder(in: container),
            historyManager: historyManager,
            downloadManager: downloadManager,
            tabManager: self,
            isPrivate: isPrivate
        )
        modelContext.insert(newTab)
        container.tabs.append(newTab)
        // Spaces are not cookie jars any more; a space only names the container its new
        // tabs start in. nil means no container, which is the shared default store.
        newTab.browsingContainer = container.defaultBrowsingContainer
        newTab.lastAccessedAt = Date()
        container.lastAccessedAt = Date()
        ExtensionManager.shared.tabDidOpen(newTab)

        // Through `activateTab`, so a tab added to another space brings the sidebar with
        // it: the hand-rolled version here set `activeTab` and left `activeContainer`
        // pointing at the space the user was looking at before.
        if activateAfterAdding {
            activateTab(newTab)
        }

        saveOrLog(modelContext)
        return newTab
    }

    /// Every "new tab" path lands here: a tab showing `aura://home`, which renders the
    /// search field and shortcuts natively instead of a blank web view.
    @discardableResult
    func openHomeTab(
        historyManager: HistoryManager? = nil,
        downloadManager: DownloadManager? = nil,
        isPrivate: Bool
    ) -> Tab? {
        guard let container = activeContainer else { return nil }
        return addTab(
            url: .oraHome,
            container: container,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: isPrivate
        )
    }

    /// Focuses the active space's `aura://settings` tab, or opens one. Settings render
    /// natively in the tab, so the tab never gets a web view.
    @discardableResult
    func openSettingsTab(
        section: SettingsTab? = nil,
        historyManager: HistoryManager? = nil,
        downloadManager: DownloadManager? = nil,
        isPrivate: Bool
    ) -> Tab? {
        guard let container = activeContainer else { return nil }
        let url = URL.oraSettings(section: section)

        if let existing = container.tabs.first(where: { $0.url.isOraSettings }) {
            existing.url = url
            existing.urlString = url.absoluteString
            activateTab(existing)
            return existing
        }

        let tab = addTab(
            url: url,
            container: container,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: isPrivate
        )
        tab.title = "Settings"
        tab.favicon = nil
        saveOrLog(modelContext)
        return tab
    }

    /// Focuses the active space's `aura://extensions` tab, or opens one. The add-on store
    /// renders natively in the tab, so it never gets a web view either.
    @discardableResult
    func openExtensionsStore(
        historyManager: HistoryManager? = nil,
        downloadManager: DownloadManager? = nil,
        isPrivate: Bool
    ) -> Tab? {
        guard let container = activeContainer else { return nil }

        if let existing = container.tabs.first(where: { $0.url.isOraExtensions }) {
            activateTab(existing)
            return existing
        }

        let tab = addTab(
            url: .oraExtensions,
            container: container,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: isPrivate
        )
        tab.title = "Extensions"
        tab.favicon = nil
        saveOrLog(modelContext)
        return tab
    }

    @discardableResult
    func openTab(
        url: URL,
        historyManager: HistoryManager,
        downloadManager: DownloadManager? = nil,
        focusAfterOpening: Bool = true,
        isPrivate: Bool,
        loadSilently: Bool = false
    ) -> Tab? {
        guard let container = activeContainer else { return nil }
        // aura:// pages have a host too, but they render natively: no favicon to fetch
        // and no web view to build. This used to be wrapped in `if let host = url.host`,
        // so every internal address opened nothing at all.
        let isInternal = url.isOraInternal
        let host = isInternal ? nil : url.host
        let cleanHost = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        let fileName = url.isFileURL ? url.lastPathComponent : nil

        let newTab = Tab(
            url: isInternal ? url.canonicalOraInternal : url,
            // A file URL has no host, so without the file name every opened document
            // would sit in the sidebar as "New Tab" until WebKit reported a title.
            title: url.isOraHome ? "New Tab" : (cleanHost ?? fileName ?? "New Tab"),
            favicon: host.flatMap { FaviconService.shared.faviconURL(for: $0) },
            container: container,
            type: .normal,
            isPlayingMedia: false,
            order: nextTabOrder(in: container),
            historyManager: historyManager,
            downloadManager: downloadManager,
            tabManager: self,
            isPrivate: isPrivate
        )
        modelContext.insert(newTab)
        container.tabs.append(newTab)
        newTab.browsingContainer = container.defaultBrowsingContainer
        ExtensionManager.shared.tabDidOpen(newTab)
        // The one place a URL becomes a new tab, so it is also where the file tray hears
        // about a file opened from Finder, the dock, ⌘O or a drop. The gate records the
        // ones that are readable and asks for the ones that are not, which is the route a
        // path typed into the launcher takes.
        if url.isFileURL {
            FileOpenService.shared.prepareToOpen(url, tabID: newTab.id, isPrivate: isPrivate)
        }

        if focusAfterOpening {
            activateTab(newTab)
        }
        if focusAfterOpening || loadSilently {
            // Initialize the WebView for the new active tab. An internal page returns
            // from here without one.
            newTab.restoreTransientState(
                historyManager: historyManager,
                downloadManager: downloadManager ?? DownloadManager(
                    modelContainer: modelContainer,
                    modelContext: modelContext
                ),
                tabManager: self,
                isPrivate: isPrivate
            )
        }

        container.lastAccessedAt = Date()
        saveOrLog(modelContext)
        return newTab
    }

    func reorderTabs(from: Tab, toTab: Tab) {
        from.container.reorderTabs(from: from, to: toTab)
        saveOrLog(modelContext)
    }

    func switchSections(from: Tab, toTab: Tab) {
        from.switchSections(from: from, to: toTab)
        saveOrLog(modelContext)
    }

    /// The row the selection falls to when `tab` goes. The sidebar sorts descending, so
    /// the neighbour below is the next lower `order` in the same section and folder;
    /// closing the last row of a folder falls back to the space's most recent tab.
    /// Hibernated tabs count: `activateTab` rebuilds the web view on the way in.
    func neighbour(after tab: Tab) -> Tab? {
        let remaining = tab.container.tabs.filter { $0.id != tab.id }
        let siblings = remaining
            .filter { $0.type == tab.type && $0.folder?.id == tab.folder?.id }
            .sorted { $0.order > $1.order }
        if let below = siblings.first(where: { $0.order < tab.order }) { return below }
        if let above = siblings.last(where: { $0.order > tab.order }) { return above }
        return remaining
            .sorted { ($0.lastAccessedAt ?? .distantPast) > ($1.lastAccessedAt ?? .distantPast) }
            .first
    }

    func closeTab(tab: Tab, shouldTrackForRestore: Bool = true) {
        FindManager.shared.endSession(for: tab.id)
        ExtensionManager.shared.tabDidClose(tab)
        // An unpinned tray row is a record of what is open, so it goes with the tab, and
        // a consent prompt for a tab that is gone must not answer for the tab that
        // replaces it.
        OpenedFileStore.shared.tabClosed(tab.id)
        FileOpenService.shared.cancelConsent(forTab: tab.id)
        // If the closed tab was active, select another tab. No tabs left in the space
        // means no active tab, which is what puts aura://home back on screen.
        if self.activeTab?.id == tab.id {
            tab.maybeIsActive = false
            if let nextTab = neighbour(after: tab) {
                self.activateTab(nextTab)
            } else {
                self.activeTab = nil
            }
        }
        if shouldTrackForRestore, tab.type == .normal {
            trackRecentlyClosedTab(tab)
        }
        // Pausing the media and closing any PiP window takes two web-process round
        // trips. The row used to wait on both, so a tab that never loaded a page still
        // sat in the sidebar for a turn of the main queue. `stopMedia` detaches the page
        // itself, which is what `destroyWebView` did here.
        tab.stopMedia()
        mediaController.removeSession(for: tab.id)
        var deleted: [UUID] = []
        if tab.type == .normal {
            let id = tab.id
            if deleteIfPresent(tab) { deleted.append(id) }
        }
        saveOrLog(modelContext)
        announceDeletedTabs(deleted)
    }

    func closeActiveTab() {
        if let tab = activeTab {
            closeTab(tab: tab)
        } else {
            NSApp.keyWindow?.close()
        }
    }

    func togglePiP(_ currentTab: Tab?, _ oldTab: Tab?) {
        guard currentTab?.id != oldTab?.id, SettingsStore.shared.autoPiPEnabled else { return }
        // Two web-process round trips on every tab switch, and neither can do anything
        // when no media is playing on either side of the switch.
        guard currentTab?.isPlayingMedia == true || oldTab?.isPlayingMedia == true else { return }
        currentTab?.evaluateJavaScript("window.__oraTriggerPiP(true)")
        oldTab?.evaluateJavaScript("window.__oraTriggerPiP()")
    }

    func activateTab(_ tab: Tab) {
        // Toggle Picture-in-Picture on tab switch
        togglePiP(tab, activeTab)

        // Activate the tab
        let previousTab = activeTab
        // Leaving a tab is the moment its session is worth writing: neither its back
        // list nor its scroll offset can move again while it is off screen.
        if let previousTab, previousTab.id != tab.id {
            previousTab.recordScrollOffset()
            sessionStore.scheduleCapture(previousTab)
        }
        activeTab?.maybeIsActive = false
        activeTab = tab
        activeTab?.maybeIsActive = true
        ExtensionManager.shared.tabDidActivate(tab, previous: previousTab)
        tab.lastAccessedAt = Date()
        activeContainer = tab.container
        tab.container.lastAccessedAt = Date()

        // Lazy load WebView if not ready
        if !tab.isWebViewReady {
            tab.restoreTransientState(
                historyManager: tab.historyManager ?? HistoryManager(
                    modelContainer: modelContainer,
                    modelContext: modelContext
                ),
                downloadManager: tab.downloadManager ?? DownloadManager(
                    modelContainer: modelContainer,
                    modelContext: modelContext
                ),
                tabManager: self,
                isPrivate: tab.isPrivate
            )
        }
        tab.updateHeaderColor()
        saveOrLog(modelContext)
    }

    /// Start the automatic cleanup timer
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.runTabMaintenance()
            }
        }
    }

    deinit {
        cleanupTimer?.invalidate()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let deletionObserver {
            NotificationCenter.default.removeObserver(deletionObserver)
        }
    }

    /// Activate a tab by its persistent id. `activateTab` follows the tab into its own
    /// space, so the container needs no separate switch.
    func activateTab(id: UUID) {
        for container in fetchContainers() {
            if let tab = container.tabs.first(where: { $0.id == id }) {
                activateTab(tab)
                return
            }
        }
    }

    func selectTabAtIndex(_ index: Int) {
        guard let container = activeContainer else { return }

        // Match the sidebar ordering: favorites, then pinned, then normal tabs
        // All sorted by order in descending order
        let favoriteTabs = container.tabs
            .filter { $0.type == .fav }
            .sorted(by: { $0.order > $1.order })

        let pinnedTabs = container.tabs
            .filter { $0.type == .pinned }
            .sorted(by: { $0.order > $1.order })

        let normalTabs = container.tabs
            .filter { $0.type == .normal }
            .sorted(by: { $0.order > $1.order })

        // Combine all tabs in the same order as the sidebar
        let allTabs = favoriteTabs + pinnedTabs + normalTabs

        // Handle special case: Command+9 selects the last tab
        let targetIndex = (index == 9) ? allTabs.count - 1 : index - 1

        // Validate index is within bounds
        guard targetIndex >= 0, targetIndex < allTabs.count else { return }

        let targetTab = allTabs[targetIndex]
        activateTab(targetTab)
    }

    func fetchContainers() -> [TabContainer] {
        do {
            let descriptor = FetchDescriptor<TabContainer>(sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)])
            return try modelContext.fetch(descriptor)
        } catch {
            // Failed to fetch containers
        }
        return []
    }

    /// The copy lands next to the original, in the same folder. `openTab` is not used
    /// here: it needs a host, so it silently dropped aura:// tabs on the floor, and it
    /// always opens in the active space rather than the source tab's.
    @discardableResult
    func duplicateTab(_ tab: Tab) -> Tab {
        // The copy keeps the original's section: created as `.normal`, a copy of a
        // pinned or favourite tab tripped `reorderTabs`' type guard and landed at the
        // end of the normal list instead of beside the tab it came from.
        let copy = Tab(
            url: tab.url,
            title: tab.title,
            favicon: tab.favicon,
            container: tab.container,
            type: tab.type,
            order: nextTabOrder(in: tab.container),
            historyManager: tab.historyManager,
            downloadManager: tab.downloadManager,
            tabManager: self,
            isPrivate: tab.isPrivate
        )
        copy.faviconLocalFile = tab.faviconLocalFile
        // Pinned and favourite tabs reopen at the URL they were pinned at.
        copy.savedURL = tab.savedURL
        modelContext.insert(copy)
        tab.container.tabs.append(copy)
        // A copy of a tab belongs in the same cookie jar as the tab it came from, which
        // is not always the space default.
        copy.browsingContainer = tab.browsingContainer
        copy.folder = tab.folder
        ExtensionManager.shared.tabDidOpen(copy)
        tab.container.reorderTabs(from: copy, to: tab)

        if !tab.url.isOraInternal, let historyManager = tab.historyManager {
            copy.restoreTransientState(
                historyManager: historyManager,
                downloadManager: tab.downloadManager ?? DownloadManager(
                    modelContainer: modelContainer,
                    modelContext: modelContext
                ),
                tabManager: self,
                isPrivate: tab.isPrivate
            )
        }
        saveOrLog(modelContext)
        return copy
    }

    func refreshPrivacySettings(for containerId: UUID) {
        guard let container = fetchContainer(id: containerId) else { return }

        let loadedTabs = container.tabs.filter(\.isWebViewReady)
        guard !loadedTabs.isEmpty else { return }

        for tab in loadedTabs {
            tab.refreshBrowserPageForPrivacySettings()
        }
    }

}
