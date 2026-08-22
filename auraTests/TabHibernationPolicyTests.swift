@testable import Aura
import Foundation
import SwiftData
import Testing

/// The pressure policy ported from Nook: the weighted score, the grace period and the
/// throttle on the memory-pressure source. No web views are built, so `destroyWebView`
/// never runs; what is checked here is which tabs the policy picks and when.
@MainActor
struct TabHibernationPolicyTests {
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
        return (manager, manager.createContainer(name: "Policy Space"))
    }

    @discardableResult
    private func makeTab(
        _ manager: TabManager,
        _ space: TabContainer,
        index: Int,
        type: TabType = .normal,
        lastAccessedAt: Date
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
        tab.lastAccessedAt = lastAccessedAt
        tab.isWebViewReady = true
        manager.modelContext.insert(tab)
        space.tabs.append(tab)
        try manager.modelContext.save()
        return tab
    }

    // MARK: - Scoring

    @Test func theScoreRanksActiveOverMediaOverPinnedOverIdle() throws {
        let (manager, space) = try makeManager()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let idleFor = { (minutes: Double) in now.addingTimeInterval(-minutes * 60) }

        let active = try makeTab(manager, space, index: 0, lastAccessedAt: idleFor(90))
        let media = try makeTab(manager, space, index: 1, lastAccessedAt: idleFor(90))
        let pinned = try makeTab(manager, space, index: 2, type: .pinned, lastAccessedAt: idleFor(90))
        let idle = try makeTab(manager, space, index: 3, lastAccessedAt: idleFor(90))
        manager.activateTab(active)
        media.isPlayingMedia = true

        let policy = manager.hibernationPolicy
        let scores = [active, media, pinned, idle].map { policy.importanceScore($0, now: now) }
        #expect(scores == scores.sorted(by: >), "active > media > pinned > idle")
        #expect(policy.evictionOrder([active, media, pinned, idle], now: now).first?.id == idle.id)
    }

    @Test func recencyBreaksTiesAndNeverGoesNegative() throws {
        let (manager, space) = try makeManager()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = try makeTab(manager, space, index: 0, lastAccessedAt: now.addingTimeInterval(-60))
        let stale = try makeTab(manager, space, index: 1, lastAccessedAt: now.addingTimeInterval(-86400))
        let never = try makeTab(manager, space, index: 2, lastAccessedAt: .distantPast)

        let policy = manager.hibernationPolicy
        #expect(policy.importanceScore(fresh, now: now) > policy.importanceScore(stale, now: now))
        // 100 - minutes floors at zero rather than running away into negative numbers.
        #expect(policy.importanceScore(stale, now: now) == 0)
        #expect(policy.importanceScore(never, now: now) == 0)
    }

    @Test func unsavedInputOutranksAPlainIdleTab() throws {
        let (manager, space) = try makeManager()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let typing = try makeTab(manager, space, index: 0, lastAccessedAt: now.addingTimeInterval(-3600))
        let idle = try makeTab(manager, space, index: 1, lastAccessedAt: now.addingTimeInterval(-3600))

        let policy = manager.hibernationPolicy
        #expect(policy.importanceScore(typing, now: now) == policy.importanceScore(idle, now: now))

        policy.tabsWithUnsavedInput.insert(typing.id)
        #expect(policy.importanceScore(typing, now: now) > policy.importanceScore(idle, now: now))
        #expect(policy.evictionOrder([typing, idle], now: now).first?.id == idle.id)
    }

    // MARK: - Grace period

    @Test func aTabJustLeftBehindIsNotYetEvictable() throws {
        let (manager, space) = try makeManager()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let justLeft = try makeTab(manager, space, index: 0, lastAccessedAt: now.addingTimeInterval(-10))
        let settled = try makeTab(manager, space, index: 1, lastAccessedAt: now.addingTimeInterval(-60))

        let policy = manager.hibernationPolicy
        #expect(policy.isEligible(justLeft, now: now) == false)
        #expect(policy.isEligible(settled, now: now))
        // The boundary itself counts as elapsed.
        let onTheLine = now.addingTimeInterval(-TabHibernationPolicy.gracePeriod)
        justLeft.lastAccessedAt = onTheLine
        #expect(policy.isEligible(justLeft, now: now))
    }

    @Test func theActivePinnedAndPlayingTabsAreNeverEligible() throws {
        let (manager, space) = try makeManager()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let long = now.addingTimeInterval(-86400)
        let active = try makeTab(manager, space, index: 0, lastAccessedAt: long)
        let pinned = try makeTab(manager, space, index: 1, type: .pinned, lastAccessedAt: long)
        let playing = try makeTab(manager, space, index: 2, lastAccessedAt: long)
        let unloaded = try makeTab(manager, space, index: 3, lastAccessedAt: long)
        manager.activateTab(active)
        active.lastAccessedAt = long
        playing.isPlayingMedia = true
        unloaded.isWebViewReady = false

        let policy = manager.hibernationPolicy
        #expect(policy.isEligible(active, now: now) == false)
        #expect(policy.isEligible(pinned, now: now) == false)
        #expect(policy.isEligible(playing, now: now) == false)
        #expect(policy.isEligible(unloaded, now: now) == false)
    }

    // MARK: - Triggers

    @Test func memoryPressureUnloadsThePresetsShareLeastImportantFirst() throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previous = store.hibernationPreset
        defer { store.hibernationPreset = previous }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0 ..< 8 {
            // Older index means longer idle, so index 7 is the freshest.
            try makeTab(manager, space, index: index, lastAccessedAt: now.addingTimeInterval(-Double(8 - index) * 60))
        }

        store.hibernationPreset = .balanced
        let policy = manager.hibernationPolicy
        let doomed = policy.handleMemoryPressure(now: now)
        #expect(doomed.count == 4, "balanced unloads half of the eight idle tabs")
        #expect(doomed.first?.title == "tab 0", "the stalest tab goes first")
    }

    @Test func repeatPressureEventsInsideTheThrottleAreIgnored() throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previous = store.hibernationPreset
        defer { store.hibernationPreset = previous }
        store.hibernationPreset = .aggressive

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0 ..< 4 {
            try makeTab(manager, space, index: index, lastAccessedAt: now.addingTimeInterval(-3600))
        }

        let policy = manager.hibernationPolicy
        #expect(policy.handleMemoryPressure(now: now).count == 4)

        // Same second and one second short of the throttle: both no-ops.
        #expect(policy.handleMemoryPressure(now: now).isEmpty)
        let almost = now.addingTimeInterval(TabHibernationPolicy.pressureThrottle - 1)
        #expect(policy.handleMemoryPressure(now: almost).isEmpty)
    }

    @Test func resigningActiveOnlyUnloadsWhenTheSettingIsOn() throws {
        let (manager, space) = try makeManager()
        let store = SettingsStore.shared
        let previous = store.unloadTabsOnResign
        defer { store.unloadTabsOnResign = previous }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0 ..< 3 {
            try makeTab(manager, space, index: index, lastAccessedAt: now.addingTimeInterval(-3600))
        }

        let policy = manager.hibernationPolicy
        store.unloadTabsOnResign = false
        #expect(policy.handleAppResignActive(now: now).isEmpty)

        store.unloadTabsOnResign = true
        #expect(policy.handleAppResignActive(now: now).count == 3)
    }

    @Test func everyPresetUnloadsSomethingAndAggressiveTakesTheLot() {
        #expect(TabHibernationPreset.allCases.count == 3)
        for preset in TabHibernationPreset.allCases {
            #expect(preset.pressureUnloadFraction > 0)
            #expect(preset.pressureUnloadFraction <= 1)
            #expect(!preset.title.isEmpty)
            #expect(!preset.summary.isEmpty)
        }
        #expect(TabHibernationPreset.aggressive.pressureUnloadFraction == 1)
        #expect(
            TabHibernationPreset.conservative.pressureUnloadFraction
                < TabHibernationPreset.balanced.pressureUnloadFraction
        )
    }

    @Test func eachWindowKeepsItsOwnPolicy() throws {
        let (first, _) = try makeManager()
        let (second, _) = try makeManager()
        #expect(first.hibernationPolicy === first.hibernationPolicy)
        #expect(first.hibernationPolicy !== second.hibernationPolicy)
    }
}
