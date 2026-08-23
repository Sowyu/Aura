import Foundation
@testable import Aura
import SwiftData
import Testing

// swiftlint:disable no_print_statements
// The memory benchmark's output is its deliverable.

@MainActor
struct TabHibernationTests {
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
        let space = manager.createContainer(name: "Hibernation Space")
        return (manager, space)
    }

    @discardableResult
    private func makeTab(
        _ manager: TabManager,
        _ space: TabContainer,
        index: Int,
        type: TabType = .normal
    ) throws -> Tab {
        let tab = try Tab(
            url: #require(URL(string: "https://example.com/\(index)")),
            title: "tab \(index)",
            container: space,
            type: type,
            order: index,
            tabManager: manager,
            isPrivate: false
        )
        // Oldest first: index 0 is the least recently touched, so it goes first.
        tab.lastAccessedAt = Date(timeIntervalSince1970: 1_000_000 + Double(index))
        manager.modelContext.insert(tab)
        // Both sides, like `addTab` does: setting only `Tab.container` leaves the
        // relationship array stale once anything re-fetches the space.
        space.tabs.append(tab)
        try manager.modelContext.save()
        return tab
    }

    /// Lets one turn of the main queue run, for the paths that finish on a hop.
    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// No web views are built here. A tab whose `browserPage` is nil answers the
    /// unsaved-input probe immediately, so the whole eviction pass runs synchronously
    /// and the selection rules can be checked without spawning 20 content processes.
    @Test func liveTabCapEvictsOldestAndSparesActiveMediaAndPinned() throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previousLimit = store.maxLiveTabs
        defer { store.maxLiveTabs = previousLimit }
        store.maxLiveTabs = 5

        var tabs: [Tab] = []
        for index in 0 ..< 20 {
            let tab = try makeTab(manager, space, index: index, type: index == 1 ? .pinned : .normal)
            tab.isWebViewReady = true
            tabs.append(tab)
        }
        let activeTab = tabs[0]
        let mediaTab = tabs[2]
        let pinnedTab = tabs[1]
        manager.activateTab(activeTab)
        activeTab.isWebViewReady = true
        mediaTab.isPlayingMedia = true

        #expect(manager.liveWebViewCount() == 20)
        manager.enforceLiveTabLimit()

        #expect(manager.liveWebViewCount() == 5)
        #expect(activeTab.isWebViewReady, "the active tab is never unloaded")
        #expect(mediaTab.isWebViewReady, "a tab playing media is never unloaded")
        #expect(pinnedTab.isWebViewReady, "pinned tabs are kept warm on purpose")
        // Two survivors are left over after the three protected tabs: the two most
        // recently touched normal tabs.
        #expect(tabs[19].isWebViewReady)
        #expect(tabs[18].isWebViewReady)
        #expect(!tabs[3].isWebViewReady, "the oldest evictable tab goes first")
    }

    @Test func hibernationKeepsTheRowAndItsIdentity() throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previousLimit = store.maxLiveTabs
        defer { store.maxLiveTabs = previousLimit }
        store.maxLiveTabs = 1

        let keeper = try makeTab(manager, space, index: 0)
        let victim = try makeTab(manager, space, index: 1)
        keeper.isWebViewReady = true
        victim.isWebViewReady = true
        manager.activateTab(keeper)
        keeper.isWebViewReady = true

        manager.enforceLiveTabLimit()

        #expect(!victim.isWebViewReady)
        #expect(victim.browserPage == nil, "the web view is gone")
        #expect(space.tabs.contains { $0.id == victim.id }, "the tab itself survives")
        #expect(victim.url.absoluteString == "https://example.com/1", "the URL survives")
        #expect(victim.title == "tab 1")
        #expect(victim.backgroundColorHex == "#000000", "the header colour survives")
    }

    /// One `TabManager` per window, one store between them. Evicting on this manager's
    /// `activeTab` alone blanked the page the other window was showing.
    @Test func aTabActiveInAnotherWindowIsNeverEvicted() throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previousLimit = store.maxLiveTabs
        defer { store.maxLiveTabs = previousLimit }
        store.maxLiveTabs = 1

        let mine = try makeTab(manager, space, index: 0)
        let theirs = try makeTab(manager, space, index: 1)
        let spare = try makeTab(manager, space, index: 2)
        for tab in [mine, theirs, spare] { tab.isWebViewReady = true }

        let secondWindow = TabManager(
            modelContainer: manager.modelContainer,
            modelContext: manager.modelContext,
            mediaController: MediaController()
        )
        manager.activateTab(mine)
        secondWindow.activateTab(theirs)
        for tab in [mine, theirs, spare] { tab.isWebViewReady = true }

        manager.enforceLiveTabLimit()

        // Reading the second manager here also keeps it alive across the eviction pass;
        // the registry only holds it weakly.
        #expect(secondWindow.activeTab?.id == theirs.id)
        #expect(mine.isWebViewReady, "this window's tab stays")
        #expect(theirs.isWebViewReady, "the other window's tab stays too")
        #expect(!spare.isWebViewReady, "the tab no window is showing goes")
    }

    @Test func loweringTheCapInSettingsTakesEffectImmediately() async throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previousLimit = store.maxLiveTabs
        defer { store.maxLiveTabs = previousLimit }
        store.maxLiveTabs = 8

        var tabs: [Tab] = []
        for index in 0 ..< 4 {
            let tab = try makeTab(manager, space, index: index)
            tab.isWebViewReady = true
            tabs.append(tab)
        }
        manager.activateTab(tabs[3])
        for tab in tabs { tab.isWebViewReady = true }
        #expect(manager.liveWebViewCount() == 4)

        // No timer tick, no window event: only the settings write.
        store.maxLiveTabs = 1
        try await Task.sleep(for: .milliseconds(100))

        #expect(manager.liveWebViewCount() == 1)
        #expect(tabs[3].isWebViewReady)
    }

    @Test func mediaVetoesEvictionUnlessTheSettingSaysOtherwise() throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previousLimit = store.maxLiveTabs
        let previousUnload = store.unloadMediaTabs
        defer {
            store.maxLiveTabs = previousLimit
            store.unloadMediaTabs = previousUnload
        }
        store.maxLiveTabs = 1
        store.unloadMediaTabs = false

        let keeper = try makeTab(manager, space, index: 0)
        let playing = try makeTab(manager, space, index: 1)
        keeper.isWebViewReady = true
        playing.isWebViewReady = true
        playing.isPlayingMedia = true
        manager.activateTab(keeper)
        keeper.isWebViewReady = true

        manager.enforceLiveTabLimit()
        #expect(playing.isWebViewReady, "playback vetoes the unload")

        store.unloadMediaTabs = true
        manager.enforceLiveTabLimit()
        #expect(!playing.isWebViewReady, "unless the user opted in")
    }

    /// The unsaved-input probe is a round trip and can veto an unload. One veto used to
    /// end the pass, leaving the cap violated until the next minute tick.
    @Test func aVetoedUnloadIsFollowedByAnotherCandidate() throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previousLimit = store.maxLiveTabs
        defer { store.maxLiveTabs = previousLimit }
        store.maxLiveTabs = 2

        var tabs: [Tab] = []
        for index in 0 ..< 4 {
            let tab = try makeTab(manager, space, index: index)
            tab.isWebViewReady = true
            tabs.append(tab)
        }
        manager.activateTab(tabs[3])
        for tab in tabs { tab.isWebViewReady = true }
        // Typing in progress on the oldest tab: the probe answers "dirty".
        tabs[0].unsavedInputProbe = { $0(true) }

        manager.enforceLiveTabLimit()

        #expect(tabs[0].isWebViewReady, "a tab with unsaved typing is left alone")
        #expect(manager.liveWebViewCount() == 2, "the cap still holds after the veto")
    }

    /// Expiry is not a close the user made, so it must not fill the reopen stack.
    @Test func autoClearedTabsAreNotTrackedForReopening() throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previous = store.autoClearTabsAfter(for: space.id)
        defer { store.setAutoClearTabsAfter(previous, for: space.id) }
        store.setAutoClearTabsAfter(.oneHour, for: space.id)

        let stale = try makeTab(manager, space, index: 0)
        stale.lastAccessedAt = Date().addingTimeInterval(-7200)

        manager.autoClearContainerTabs()

        #expect(!space.tabs.contains { $0.id == stale.id }, "the expired tab goes")
        #expect(manager.recentlyClosedTabs.isEmpty, "and it is not offered back as a recent close")
    }

    /// The offset is re-applied once, and only to the page it was taken from.
    @Test func scrollIsRestoredOnlyForTheSamePage() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, index: 0)
        tab.hibernatedScrollOffset = CGPoint(x: 0, y: 640)
        tab.hibernatedScrollURL = tab.url

        tab.restoreScrollOffsetIfNeeded()

        #expect(tab.hibernatedScrollOffset == nil, "the offset is consumed")
        #expect(tab.hibernatedScrollURL == nil)

        let other = try makeTab(manager, space, index: 1)
        other.hibernatedScrollOffset = CGPoint(x: 0, y: 640)
        other.hibernatedScrollURL = try #require(URL(string: "https://example.com/elsewhere"))

        other.restoreScrollOffsetIfNeeded()

        #expect(other.hibernatedScrollOffset != nil, "a different page keeps its own offset")
    }

    // MARK: - Memory benchmark

    nonisolated static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["ORA_BENCH"] == "1" || environment["TEST_RUNNER_ORA_BENCH"] == "1"
    }

    /// `phys_footprint` is the number Xcode's memory gauge and jetsam both use. Note it
    /// counts this process only: a `WKWebView`'s page memory lives in its own content
    /// process, so the drop measured here is the host-side share, not the whole saving.
    private static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    /// A `WKWebView`'s page memory lives in its own WebContent process, not in this
    /// one, so the host footprint alone understates what hibernation frees. Other apps'
    /// WebContent processes are counted too; they are steady across a single run, so the
    /// before/after delta is still this test's own.
    private static func webContentUsage() -> (count: Int, totalMB: Double) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "rss,comm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return (-1, 0) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let rows = (String(bytes: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .filter { $0.contains("com.apple.WebKit.WebContent") }
        let kilobytes = rows.reduce(0.0) { total, row in
            total + (Double(row.trimmingCharacters(in: .whitespaces).prefix(while: \.isNumber)) ?? 0)
        }
        return (rows.count, kilobytes / 1024)
    }

    private func openBenchTabs(
        count: Int,
        manager: TabManager,
        space: TabContainer,
        historyManager: HistoryManager,
        downloadManager: DownloadManager
    ) throws -> [Tab] {
        var tabs: [Tab] = []
        for index in 0 ..< count {
            let tab = try Tab(
                url: #require(URL(string: "about:blank")),
                title: "bench \(index)",
                container: space,
                order: index,
                tabManager: manager,
                isPrivate: false
            )
            tab.lastAccessedAt = Date(timeIntervalSince1970: 1_000_000 + Double(index))
            manager.modelContext.insert(tab)
            tab.restoreTransientState(
                historyManager: historyManager,
                downloadManager: downloadManager,
                tabManager: manager,
                isPrivate: false
            )
            tabs.append(tab)
        }
        return tabs
    }

    @Test(.enabled(if: TabHibernationTests.isEnabled))
    func twentyTabsShrinkAfterEviction() async throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previousLimit = store.maxLiveTabs
        defer { store.maxLiveTabs = previousLimit }
        store.maxLiveTabs = 0

        let historyManager = HistoryManager(
            modelContainer: manager.modelContainer,
            modelContext: manager.modelContext
        )
        let downloadManager = DownloadManager(
            modelContainer: manager.modelContainer,
            modelContext: manager.modelContext
        )

        let baseline = Self.residentMB()
        let tabs = try openBenchTabs(
            count: 20,
            manager: manager,
            space: space,
            historyManager: historyManager,
            downloadManager: downloadManager
        )
        manager.activateTab(tabs[19])

        // Let all 20 pages finish loading and their content processes settle.
        try await Task.sleep(for: .seconds(5))
        let liveBefore = manager.liveWebViewCount()
        let rssBefore = Self.residentMB()
        let webBefore = Self.webContentUsage()
        print("MEM live=\(liveBefore) rss=\(String(format: "%.1f", rssBefore))MB "
            + "webcontent=\(webBefore.count)/\(String(format: "%.1f", webBefore.totalMB))MB "
            + "baseline=\(String(format: "%.1f", baseline))MB")

        store.maxLiveTabs = 4
        manager.enforceLiveTabLimit()
        try await Task.sleep(for: .seconds(5))

        let liveAfter = manager.liveWebViewCount()
        let rssAfter = Self.residentMB()
        let webAfter = Self.webContentUsage()
        print("MEM live=\(liveAfter) rss=\(String(format: "%.1f", rssAfter))MB "
            + "webcontent=\(webAfter.count)/\(String(format: "%.1f", webAfter.totalMB))MB")
        print("MEM delta rss=\(String(format: "%.1f", rssBefore - rssAfter))MB "
            + "webcontent=\(webBefore.count - webAfter.count)"
            + "/\(String(format: "%.1f", webBefore.totalMB - webAfter.totalMB))MB "
            + "evicted=\(liveBefore - liveAfter)")

        #expect(liveBefore == 20, "all 20 tabs should start live")
        #expect(liveAfter <= 4, "the cap should hold after eviction")
    }

    /// The memory-pressure source was armed by the first maintenance tick, up to a
    /// minute after launch. A new manager has to be armed straight away.
    @Test func memoryPressureIsArmedFromInit() throws {
        let (manager, _) = try makeManager()
        #expect(manager.hibernationPolicy.isArmed)
    }

    /// `isActiveInAnyWindow` reads every window's `activeTab`, so a window still holding
    /// a tab another window deleted kept the ghost exempt from every eviction pass.
    @Test func aTabDeletedInAnotherWindowStopsBlockingEviction() async throws {
        let (windowA, space) = try makeManager()
        let doomed = try makeTab(windowA, space, index: 1)
        let survivor = try makeTab(windowA, space, index: 2)

        let windowB = TabManager(
            modelContainer: windowA.modelContainer,
            modelContext: ModelContext(windowA.modelContainer),
            mediaController: MediaController()
        )
        let spaceInB = try #require(windowB.fetchContainers().first { $0.id == space.id })
        let doomedInB = try #require(spaceInB.tabs.first { $0.id == doomed.id })
        windowB.activateTab(doomedInB)
        windowB.hibernating.insert(doomed.id)
        windowB.hibernationPolicy.tabsWithUnsavedInput.insert(doomed.id)
        #expect(TabManager.activeTabIDsAcrossWindows.contains(doomed.id))

        windowA.closeTab(tab: doomed)
        await settle()

        #expect(!TabManager.activeTabIDsAcrossWindows.contains(doomed.id))
        #expect(windowB.activeTab?.id == survivor.id)
        #expect(!windowB.hibernating.contains(doomed.id))
        #expect(!windowB.hibernationPolicy.tabsWithUnsavedInput.contains(doomed.id))
    }
}

// swiftlint:enable no_print_statements
