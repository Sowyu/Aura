import AppKit
@testable import Aura
import Foundation
import SwiftData
import Testing

/// The saved half of a tab: the back/forward list that is written down, which tabs keep
/// one, and what a restore is allowed to do with it.
@MainActor
struct TabHistorySnapshotTests {
    private func entries(_ prefix: String, _ count: Int) -> [TabHistoryEntry] {
        (0 ..< count).map { TabHistoryEntry(urlString: "https://\(prefix).example/\($0)", title: "\(prefix) \($0)") }
    }

    @Test func theListKeepsThePagesNearestTheOneTheTabIsOn() {
        let current = TabHistoryEntry(urlString: "https://example.com/now", title: "Now")
        let snapshot = TabHistorySnapshot.make(
            back: entries("back", 30),
            current: current,
            forward: entries("forward", 30),
            limit: 20
        )

        #expect(snapshot.entries.count == 41)
        #expect(snapshot.current == current)
        #expect(snapshot.back.count == 20)
        #expect(snapshot.forward.count == 20)
        // Nearest first on both sides, which is the order a menu lists them in.
        #expect(snapshot.back.first?.urlString == "https://back.example/29")
        #expect(snapshot.back.last?.urlString == "https://back.example/10")
        #expect(snapshot.forward.first?.urlString == "https://forward.example/0")
        #expect(snapshot.forward.last?.urlString == "https://forward.example/19")
    }

    @Test func aShortListIsNotPadded() {
        let snapshot = TabHistorySnapshot.make(
            back: entries("back", 2),
            current: TabHistoryEntry(urlString: "https://example.com/now", title: "Now"),
            forward: []
        )

        #expect(snapshot.entries.count == 3)
        #expect(snapshot.currentIndex == 2)
        #expect(snapshot.forward.isEmpty)
    }

    @Test func aTabWithNoCurrentPageSavesNothing() {
        let snapshot = TabHistorySnapshot.make(back: entries("back", 3), current: nil, forward: [])

        #expect(snapshot.isEmpty)
        #expect(snapshot.current == nil)
        #expect(snapshot.back.isEmpty)
    }

    @Test func theListSurvivesAWriteAndARead() throws {
        let original = TabHistorySnapshot.make(
            back: entries("back", 3),
            current: TabHistoryEntry(urlString: "https://example.com/now", title: "Now"),
            forward: entries("forward", 1)
        )

        let decoded = try #require(TabHistorySnapshot.decoded(from: #require(original.encoded())))
        #expect(decoded == original)
    }

    /// A row written by an older build, or half-written, must not take a restore down
    /// with it.
    @Test func anUnreadableListIsIgnoredRatherThanTrusted() {
        #expect(TabHistorySnapshot.decoded(from: nil) == nil)
        #expect(TabHistorySnapshot.decoded(from: Data("not json".utf8)) == nil)

        let broken = TabHistorySnapshot(entries: entries("back", 2), currentIndex: 7)
        #expect(broken.current == nil)
        #expect(broken.back.isEmpty)
        #expect(broken.forward.isEmpty)
    }

    /// A pinned tab reopens at the address it was pinned at, so its saved list is only
    /// restorable when that is where the list left off.
    @Test func aSavedListOnlyBelongsToThePageItEndsOn() throws {
        let snapshot = TabHistorySnapshot.make(
            back: entries("back", 1),
            current: TabHistoryEntry(urlString: "https://example.com/now", title: "Now"),
            forward: []
        )

        #expect(try snapshot.belongs(to: #require(URL(string: "https://example.com/now"))))
        #expect(try !snapshot.belongs(to: #require(URL(string: "https://example.com/pinned"))))
        #expect(try !TabHistorySnapshot().belongs(to: #require(URL(string: "https://example.com/now"))))
    }
}

// MARK: - Which tabs keep a session

@MainActor
struct TabSessionStoreTests {
    private func makeManager() throws -> (TabManager, TabContainer) {
        let modelContainer = try ModelContainer(
            for: TabContainer.self, History.self, Download.self, TabSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(modelContainer)
        let manager = TabManager(
            modelContainer: modelContainer,
            modelContext: context,
            mediaController: MediaController()
        )
        return (manager, manager.createContainer(name: "Session Space"))
    }

    @discardableResult
    private func makeTab(_ manager: TabManager, _ space: TabContainer, order: Int) throws -> Tab {
        let tab = try Tab(
            url: #require(URL(string: "https://example.com/\(order)")),
            title: "tab \(order)",
            container: space,
            order: order,
            tabManager: manager,
            isPrivate: false
        )
        manager.modelContext.insert(tab)
        space.tabs.append(tab)
        try manager.modelContext.save()
        return tab
    }

    // MARK: - The sweep

    @Test func aClosedTabsSessionGoesWithIt() {
        let live = UUID()
        let closed = UUID()
        let rows = [(tabID: live, updatedAt: Date()), (tabID: closed, updatedAt: Date())]

        let doomed = TabSessionStore.prunable(rows, liveTabIDs: [live], limit: 20)
        #expect(doomed == [closed])
    }

    @Test func onlyTheTwentyMostRecentlyUsedTabsKeepASession() {
        let now = Date()
        // Oldest first, so the twenty survivors are the tail of this list.
        let rows = (0 ..< 25).map { (tabID: UUID(), updatedAt: now.addingTimeInterval(Double($0))) }
        let live = Set(rows.map(\.tabID))

        let doomed = TabSessionStore.prunable(rows, liveTabIDs: live, limit: 20)

        #expect(doomed.count == 5)
        #expect(doomed == Set(rows.prefix(5).map(\.tabID)))
        #expect(rows.suffix(20).allSatisfy { !doomed.contains($0.tabID) })
    }

    @Test func nothingIsDroppedWhileThereIsRoom() {
        let rows = (0 ..< 20).map { _ in (tabID: UUID(), updatedAt: Date()) }
        let doomed = TabSessionStore.prunable(rows, liveTabIDs: Set(rows.map(\.tabID)), limit: 20)
        #expect(doomed.isEmpty)
    }

    // MARK: - Writing

    @Test func aScrollOffsetIsSavedAgainstTheAddressItBelongsTo() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, order: 1)

        #expect(manager.sessionStore.capture(tab, scroll: CGPoint(x: 0, y: 420), scrollURL: tab.url))
        manager.sessionStore.save()

        let saved = try #require(manager.sessionStore.session(for: tab.id))
        #expect(saved.scrollOffset == CGPoint(x: 0, y: 420))
        #expect(saved.scrollURLString == tab.url.absoluteString)
    }

    /// A minute tick asks every tab; writing a row that did not move would be a store
    /// write and a blob rewrite for nothing.
    @Test func askingTwiceForTheSameOffsetWritesOnce() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, order: 1)
        let offset = CGPoint(x: 0, y: 120)

        #expect(manager.sessionStore.capture(tab, scroll: offset, scrollURL: tab.url))
        #expect(!manager.sessionStore.capture(tab, scroll: offset, scrollURL: tab.url))
        // A tab with no live page and nothing new to say writes nothing at all.
        #expect(!manager.sessionStore.capture(tab))
    }

    @Test func aPrivateTabLeavesNothingBehind() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, order: 1)
        tab.isPrivate = true

        #expect(!manager.sessionStore.capture(tab, scroll: CGPoint(x: 0, y: 99), scrollURL: tab.url))
        #expect(manager.sessionStore.session(for: tab.id) == nil)
    }

    @Test func anInternalPageIsNotWorthASession() throws {
        let (manager, space) = try makeManager()
        let tab = try makeTab(manager, space, order: 1)
        tab.updateURL(.oraHome)

        #expect(!manager.sessionStore.capture(tab, scroll: CGPoint(x: 0, y: 99), scrollURL: tab.url))
        #expect(manager.sessionStore.session(for: tab.id) == nil)
    }

    @Test func theSweepClearsWhatItShould() throws {
        let (manager, space) = try makeManager()
        let kept = try makeTab(manager, space, order: 1)
        let gone = UUID()
        manager.sessionStore.capture(kept, scroll: CGPoint(x: 0, y: 10), scrollURL: kept.url)
        manager.modelContext.insert(TabSession(tabID: gone, scrollY: 5))
        manager.sessionStore.save()

        manager.sessionStore.prune(liveTabIDs: [kept.id])

        #expect(manager.sessionStore.session(for: kept.id) != nil)
        #expect(manager.sessionStore.session(for: gone) == nil)
    }

    /// Test containers are built from the entities a test names, and most of them have no
    /// reason to name this one.
    @Test func aStoreWithNoSessionTableIsQuietRatherThanFatal() throws {
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
        let space = manager.createContainer(name: "No Sessions")
        let tab = try makeTab(manager, space, order: 1)

        #expect(!manager.sessionStore.capture(tab, scroll: CGPoint(x: 0, y: 10), scrollURL: tab.url))
        #expect(manager.sessionStore.session(for: tab.id) == nil)
        manager.sessionStore.prune(liveTabIDs: [tab.id])
    }
}

// MARK: - Crash detection

struct SessionMarkerTests {
    @Test func theMarkersSayWhatTheLastRunDid() {
        #expect(SessionMarker.verdict(hasCleanExit: false, hasSessionStarted: false) == .firstRun)
        #expect(SessionMarker.verdict(hasCleanExit: false, hasSessionStarted: true) == .crashed)
        #expect(SessionMarker.verdict(hasCleanExit: true, hasSessionStarted: false) == .cleanExit)
        // Both present is a clean exit followed by a launch that never got to clear it,
        // which is the quit half doing its job.
        #expect(SessionMarker.verdict(hasCleanExit: true, hasSessionStarted: true) == .cleanExit)
    }

    @Test func aRunThatNeverQuitsReadsAsACrashAndOneThatDoesDoesNot() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "aura-markers-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let marker = SessionMarker(directory: root)

        // Nothing there yet: a first launch, and it leaves its own marker behind.
        #expect(marker.beginSession() == .firstRun)
        #expect(fileManager.fileExists(atPath: root.appending(path: SessionMarker.sessionStartedName).path))
        #expect(!fileManager.fileExists(atPath: root.appending(path: SessionMarker.cleanExitName).path))

        // That run died: the started marker is still there at the next launch.
        #expect(marker.beginSession() == .crashed)

        // This one quits properly.
        marker.endSession()
        #expect(fileManager.fileExists(atPath: root.appending(path: SessionMarker.cleanExitName).path))
        #expect(!fileManager.fileExists(atPath: root.appending(path: SessionMarker.sessionStartedName).path))

        #expect(marker.beginSession() == .cleanExit)
        // The clean-exit marker is consumed, so a crash after this one is still visible.
        #expect(!fileManager.fileExists(atPath: root.appending(path: SessionMarker.cleanExitName).path))
        #expect(marker.beginSession() == .crashed)
    }
}

// MARK: - What a crashed launch does with the tabs

@MainActor
struct SessionLaunchPolicyTests {
    private func makeManager() throws -> (TabManager, TabContainer) {
        let modelContainer = try ModelContainer(
            for: TabContainer.self, History.self, Download.self, TabSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(modelContainer)
        let manager = TabManager(
            modelContainer: modelContainer,
            modelContext: context,
            mediaController: MediaController()
        )
        return (manager, manager.createContainer(name: "Crash Space"))
    }

    @discardableResult
    private func makeTab(_ manager: TabManager, _ space: TabContainer, order: Int) throws -> Tab {
        let tab = try Tab(
            url: #require(URL(string: "https://example.com/\(order)")),
            title: "tab \(order)",
            container: space,
            order: order,
            tabManager: manager,
            isPrivate: false
        )
        manager.modelContext.insert(tab)
        space.tabs.append(tab)
        try manager.modelContext.save()
        return tab
    }

    /// Replays a launch with "reopen my tabs" off, after a run that crashed. Everything
    /// here is a process-wide flag, so nothing may suspend until they are back.
    private func replayCrashedLaunch(
        _ manager: TabManager,
        answer: (TabManager) -> Void
    ) throws -> [UUID] {
        let settings = SettingsStore.shared
        let previousSetting = settings.restoreTabsOnLaunch
        settings.restoreTabsOnLaunch = false
        TabManager.didApplyLaunchPolicy = false
        TabManager.deferredLaunchPolicy = false
        TabManager.previousRunCrashed = true

        let relaunched = TabManager(
            modelContainer: manager.modelContainer,
            modelContext: manager.modelContext,
            mediaController: MediaController()
        )
        #expect(relaunched.offersSessionRestore, "a crashed run puts the bar up")
        answer(relaunched)
        #expect(!relaunched.offersSessionRestore, "answering takes it down")

        TabManager.previousRunCrashed = false
        TabManager.didApplyLaunchPolicy = true
        settings.restoreTabsOnLaunch = previousSetting
        return try manager.modelContext.fetch(FetchDescriptor<Tab>()).map(\.id)
    }

    @Test func acrashedRunKeepsItsTabsUntilTheUserSaysOtherwise() async throws {
        let (manager, space) = try makeManager()
        let open = try makeTab(manager, space, order: 1)

        let surviving = try replayCrashedLaunch(manager) { $0.keepPreviousSession() }

        await settle()
        #expect(surviving.contains(open.id), "the launch policy did not get to touch them")
    }

    @Test func closingThemRunsTheLaunchPolicyLate() async throws {
        let (manager, space) = try makeManager()
        let open = try makeTab(manager, space, order: 1)
        let pinned = try makeTab(manager, space, order: 2)
        pinned.type = .pinned

        let surviving = try replayCrashedLaunch(manager) { $0.discardPreviousSession() }

        await settle()
        #expect(!surviving.contains(open.id), "the tabs the policy would have dropped go now")
        #expect(surviving.contains(pinned.id), "pinned tabs always come back")
    }

    /// `closeTab` and the launch policy both finish on a main-queue hop.
    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

// MARK: - Migration

/// The V3 → V4 stage, exercised against a store the older graph actually wrote.
@MainActor
struct TabSessionMigrationTests {
    /// Writes a store with the shipping pre-session schema.
    private func writeV3Store(at url: URL) throws -> (space: UUID, visit: UUID, bookmark: UUID) {
        let ids = (space: UUID(), visit: UUID(), bookmark: UUID())
        try autoreleasepool {
            let schema = Schema(versionedSchema: AuraSchemaV3.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let space = TabContainer(id: ids.space, name: "Old Space")
            context.insert(space)
            let now = Date()
            try context.insert(History(
                id: ids.visit,
                url: #require(URL(string: "https://example.com/visited")),
                title: "old visit",
                createdAt: now,
                lastAccessedAt: now,
                visitCount: 1,
                container: space
            ))
            context.insert(Bookmark(id: ids.bookmark, title: "Saved", urlString: "https://example.com/saved"))
            try context.save()
        }
        return ids
    }

    @Test("a store written before sessions existed opens through the plan")
    func aV3StoreMigratesToV4() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "aura-sessions-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let storeURL = root.appending(path: "OraData.sqlite")
        let ids = try writeV3Store(at: storeURL)

        let schema = Schema(versionedSchema: AuraSchemaV4.self)
        let migrated = try ModelContainer(
            for: schema,
            migrationPlan: AuraMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: storeURL)
        )
        let context = ModelContext(migrated)

        // Nothing the old graph held moved or vanished.
        #expect(try context.fetch(FetchDescriptor<TabContainer>()).map(\.id) == [ids.space])
        #expect(try context.fetch(FetchDescriptor<History>()).map(\.id) == [ids.visit])
        #expect(try context.fetch(FetchDescriptor<Bookmark>()).map(\.id) == [ids.bookmark])
        // The new entity starts empty, which is what "no saved sessions yet" means.
        #expect(try context.fetchCount(FetchDescriptor<TabSession>()) == 0)

        // And the migrated store takes one.
        let tabID = UUID()
        context.insert(TabSession(tabID: tabID, interactionState: Data([1, 2, 3]), scrollY: 40))
        try context.save()
        let saved = try #require(try context.fetch(FetchDescriptor<TabSession>()).first)
        #expect(saved.tabID == tabID)
        #expect(saved.interactionState == Data([1, 2, 3]))
    }

    @Test func theNewStageIsNamedInTheRightOrder() {
        #expect(AuraMigrationPlan.schemas.count == AuraMigrationPlan.stages.count + 1)
        #expect(AuraSchemaV3.versionIdentifier < AuraSchemaV4.versionIdentifier)
        #expect(AuraSchemaV4.models.map { ObjectIdentifier($0) }.contains(ObjectIdentifier(TabSession.self)))
        // V3 stays frozen: the stage above is only lightweight because nothing it held
        // changed, and `Tab` is one of the entities it names by its live class.
        #expect(!AuraSchemaV3.models.map { ObjectIdentifier($0) }.contains(ObjectIdentifier(TabSession.self)))
    }
}
