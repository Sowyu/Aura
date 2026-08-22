import SwiftData
import SwiftUI

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

    var recentTabs: [Tab] {
        guard let container = activeContainer else { return [] }
        return Array(container.tabs
            .sorted { ($0.lastAccessedAt ?? Date.distantPast) > ($1.lastAccessedAt ?? Date.distantPast) }
            .prefix(SettingsStore.shared.maxRecentTabs)
        )
    }

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

    @ObservationIgnored private var cleanupTimer: Timer?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
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

        self.modelContext.undoManager = UndoManager()
        Self.registry.append(WeakTabManager(value: self))
        applyLaunchTabPolicy()
        initializeActiveContainerAndTab()

        // Start automatic cleanup timer (every minute)
        startCleanupTimer()
        observeLiveTabLimitChanges()
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

        try? modelContext.save()
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

        try? modelContext.save()
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
        try? modelContext.save()
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
        try? modelContext.save()
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
        try? modelContext.save()
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

            await PrivacyService.clearAllWebsiteData(for: containerId)

            guard let persistedContainer = fetchContainer(id: containerId) else {
                SettingsStore.shared.removeContainerSettings(for: containerId)
                return
            }

            let wasActiveContainer = activeContainer?.id == containerId
            prepareForContainerDeletion(isActiveContainer: wasActiveContainer)
            deleteContainerContents(persistedContainer, containerId: containerId)

            // Save child deletions before deleting the container.
            // In practice, SwiftData can fail when the parent and children are
            // removed in the same save pass while non-optional inverse
            // relationships still exist.
            try? modelContext.save()

            guard let containerToDelete = fetchContainer(id: containerId) else {
                SettingsStore.shared.removeContainerSettings(for: containerId)
                activateFallbackContainerIfNeeded(afterDeletingActiveContainer: wasActiveContainer)
                return
            }

            modelContext.delete(containerToDelete)
            try? modelContext.save()
            SettingsStore.shared.removeContainerSettings(for: containerId)

            activateFallbackContainerIfNeeded(afterDeletingActiveContainer: wasActiveContainer)
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

        try? modelContext.save()
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
        newTab.lastAccessedAt = Date()
        container.lastAccessedAt = Date()
        ExtensionManager.shared.tabDidOpen(newTab)

        // Through `activateTab`, so a tab added to another space brings the sidebar with
        // it: the hand-rolled version here set `activeTab` and left `activeContainer`
        // pointing at the space the user was looking at before.
        if activateAfterAdding {
            activateTab(newTab)
        }

        try? modelContext.save()
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
        try? modelContext.save()
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
        try? modelContext.save()
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
        if let container = activeContainer {
            if let host = url.host {
                let faviconURL = FaviconService.shared.faviconURL(for: host)

                let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

                let newTab = Tab(
                    url: url,
                    title: cleanHost,
                    favicon: faviconURL,
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
                ExtensionManager.shared.tabDidOpen(newTab)

                if focusAfterOpening {
                    activateTab(newTab)
                }
                if focusAfterOpening || loadSilently {
                    // Initialize the WebView for the new active tab
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
                try? modelContext.save()
                return newTab
            }
        }
        return nil
    }

    func reorderTabs(from: Tab, toTab: Tab) {
        from.container.reorderTabs(from: from, to: toTab)
        try? modelContext.save()
    }

    func switchSections(from: Tab, toTab: Tab) {
        from.switchSections(from: from, to: toTab)
        try? modelContext.save()
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
        ExtensionManager.shared.tabDidClose(tab)
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
        tab.stopMedia { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if tab.type == .normal {
                    self.modelContext.delete(tab)
                } else {
                    tab.isWebViewReady = false
                    tab.destroyWebView()
                }
                self.mediaController.removeSession(for: tab.id)
                try? self.modelContext.save()
            }
        }
    }

    func closeActiveTab() {
        if let tab = activeTab {
            closeTab(tab: tab)
        } else {
            NSApp.keyWindow?.close()
        }
    }

    func togglePiP(_ currentTab: Tab?, _ oldTab: Tab?) {
        if currentTab?.id != oldTab?.id, SettingsStore.shared.autoPiPEnabled {
            currentTab?.evaluateJavaScript("window.__oraTriggerPiP(true)")
            oldTab?.evaluateJavaScript("window.__oraTriggerPiP()")
        }
    }

    func activateTab(_ tab: Tab) {
        // Toggle Picture-in-Picture on tab switch
        togglePiP(tab, activeTab)

        // Activate the tab
        let previousTab = activeTab
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
        try? modelContext.save()
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
        let copy = Tab(
            url: tab.url,
            title: tab.title,
            favicon: tab.favicon,
            container: tab.container,
            type: .normal,
            order: nextTabOrder(in: tab.container),
            historyManager: tab.historyManager,
            downloadManager: tab.downloadManager,
            tabManager: self,
            isPrivate: tab.isPrivate
        )
        copy.faviconLocalFile = tab.faviconLocalFile
        modelContext.insert(copy)
        tab.container.tabs.append(copy)
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
        try? modelContext.save()
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

private extension TabManager {
    func fetchContainer(id: UUID) -> TabContainer? {
        let descriptor = FetchDescriptor<TabContainer>(
            predicate: #Predicate { $0.id == id }
        )

        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            return nil
        }
    }

    func prepareForContainerDeletion(isActiveContainer: Bool) {
        guard isActiveContainer else { return }

        activeTab?.maybeIsActive = false
        activeTab = nil
        activeContainer = nil
    }

    func deleteContainerContents(_ container: TabContainer, containerId: UUID) {
        for tab in Array(container.tabs) {
            if tab.isWebViewReady {
                tab.destroyWebView()
            }
            mediaController.removeSession(for: tab.id)
            modelContext.delete(tab)
        }

        for folder in Array(container.folders) {
            modelContext.delete(folder)
        }

        for history in fetchHistory(for: containerId) {
            modelContext.delete(history)
        }
    }

    func activateFallbackContainerIfNeeded(afterDeletingActiveContainer wasActiveContainer: Bool) {
        guard wasActiveContainer else { return }

        if let nextContainer = fetchContainers().first {
            activateContainer(nextContainer)
        } else {
            _ = createContainer()
        }
    }

    func fetchHistory(for containerId: UUID) -> [History] {
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { $0.container?.id == containerId }
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            return []
        }
    }
}
