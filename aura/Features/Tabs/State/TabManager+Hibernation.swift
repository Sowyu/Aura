import AppKit
import SwiftData
import SwiftUI

/// Tab hibernation: dropping a web view while keeping the tab. Three policies feed it,
/// an age cutoff (`tabAliveTimeout`), a live-view cap (`tabs.maxLive`), and the pressure
/// policy below. The first two run off the single maintenance pass in `TabManager`.

/// How hard the pressure policy leans on tabs.
///
/// Ported from Nook's `TabManagementMode` (`Settings/NookSettingsService.swift`, lines
/// 687-760) by Maciek Bagiński, GPL-3.0. Renamed to say what it does rather than which
/// hardware it suits, and cut down to the two knobs Aura's policy actually reads.
enum TabHibernationPreset: String, CaseIterable, Identifiable {
    case conservative
    case balanced
    case aggressive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conservative: return "Conservative"
        case .balanced: return "Balanced"
        case .aggressive: return "Aggressive"
        }
    }

    var summary: String {
        switch self {
        case .conservative: return "Unloads a quarter of the idle tabs when memory runs short."
        case .balanced: return "Unloads half the idle tabs when memory runs short."
        case .aggressive: return "Unloads every idle tab when memory runs short."
        }
    }

    /// Share of the evictable tabs unloaded on one memory-pressure warning.
    var pressureUnloadFraction: Double {
        switch self {
        case .conservative: return 0.25
        case .balanced: return 0.5
        case .aggressive: return 1.0
        }
    }
}

/// The *when* of hibernation, as opposed to the *how* in `Tab.destroyWebView()`.
///
/// Ported from Nook's `TabCompositorManager` (`Nook/Components/Browser/Window/
/// TabCompositorView.swift`, lines 51-337) by Maciek Bagiński, GPL-3.0. Aura keeps its
/// own web-view teardown, its unsaved-input probe and its cross-window `isActiveInAnyWindow`
/// guard; what comes from Nook is the memory-pressure source with its throttle, the
/// unload-on-resign pass, the weighted importance score and the grace period.
///
/// One per `TabManager`, because a private window runs its own in-memory store and must
/// not evict tabs out of the shared one.
@MainActor
final class TabHibernationPolicy {
    /// The pressure source fires in bursts; one pass per window of this length is plenty.
    static let pressureThrottle: TimeInterval = 30
    /// A tab is not evictable until it has been off screen this long, so flicking through
    /// tabs does not evict the one just left behind.
    static let gracePeriod: TimeInterval = 30

    private weak var manager: TabManager?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var resignObserver: NSObjectProtocol?
    private var lastPressureAt: Date?

    /// Tabs whose last unsaved-input probe came back positive. Read by the score so a
    /// half-written comment outranks an idle page even before the probe vetoes the unload.
    var tabsWithUnsavedInput: Set<UUID> = []

    /// True once the window that owned this policy has gone.
    var isOrphaned: Bool { manager == nil }

    init(manager: TabManager) {
        self.manager = manager
    }

    deinit {
        pressureSource?.cancel()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    /// Idempotent: installs the memory-pressure source and the resign observer once.
    func arm() {
        if pressureSource == nil {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { _ = self?.handleMemoryPressure() }
            }
            source.resume()
            pressureSource = source
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleAppResignActive() }
            }
        }
    }

    // MARK: - Scoring

    /// Higher means keep. Weights ported from Nook's `tabImportanceScore`, plus a term
    /// for unsaved input, which Aura knows about and Nook does not.
    func importanceScore(_ tab: Tab, now: Date = Date()) -> Int {
        var score = 0
        if manager?.isActiveInAnyWindow(tab) == true { score += 1000 }
        if tab.isPlayingMedia { score += 500 }
        if tabsWithUnsavedInput.contains(tab.id) { score += 300 }
        if tab.type != .normal { score += 200 }
        let idleMinutes = now.timeIntervalSince(tab.lastAccessedAt ?? .distantPast) / 60
        score += max(0, 100 - Int(idleMinutes.rounded(.down)))
        return score
    }

    /// The same exemptions the timeout pass uses, plus the grace period.
    func isEligible(_ tab: Tab, now: Date = Date()) -> Bool {
        guard let manager, tab.isWebViewReady, tab.type == .normal else { return false }
        guard !manager.isActiveInAnyWindow(tab) else { return false }
        guard !tab.isPlayingMedia || SettingsStore.shared.unloadMediaTabs else { return false }
        return now.timeIntervalSince(tab.lastAccessedAt ?? .distantPast) >= Self.gracePeriod
    }

    /// Least important first, which is the order they get unloaded in.
    func evictionOrder(_ tabs: [Tab], now: Date = Date()) -> [Tab] {
        tabs.sorted { importanceScore($0, now: now) < importanceScore($1, now: now) }
    }

    // MARK: - Triggers

    /// Returns the tabs it unloaded, so a test can drive it without a real pressure event.
    @discardableResult
    func handleMemoryPressure(now: Date = Date()) -> [Tab] {
        if let lastPressureAt, now.timeIntervalSince(lastPressureAt) < Self.pressureThrottle {
            return []
        }
        lastPressureAt = now
        guard let manager else { return [] }

        let candidates = manager.fetchContainers().flatMap(\.tabs).filter { isEligible($0, now: now) }
        guard !candidates.isEmpty else { return [] }

        let fraction = SettingsStore.shared.hibernationPreset.pressureUnloadFraction
        let count = min(candidates.count, Int((Double(candidates.count) * fraction).rounded(.up)))
        let doomed = Array(evictionOrder(candidates, now: now).prefix(count))
        for tab in doomed { manager.hibernate(tab) }
        return doomed
    }

    /// Aura going to the background is the cheapest moment to give memory back, but only
    /// if the user asked for it: coming back to a wall of reloading tabs is worse.
    @discardableResult
    func handleAppResignActive(now: Date = Date()) -> [Tab] {
        guard SettingsStore.shared.unloadTabsOnResign, let manager else { return [] }
        let doomed = manager.fetchContainers().flatMap(\.tabs).filter { isEligible($0, now: now) }
        for tab in doomed { manager.hibernate(tab) }
        return doomed
    }
}

@MainActor
extension TabManager {
    /// Weak-managed, one per window. Pruned on access rather than on window close, because
    /// `ObjectIdentifier` is reusable once a manager deallocates.
    private static var policies: [ObjectIdentifier: TabHibernationPolicy] = [:]

    var hibernationPolicy: TabHibernationPolicy {
        Self.policies = Self.policies.filter { !$0.value.isOrphaned }
        let key = ObjectIdentifier(self)
        if let existing = Self.policies[key] { return existing }
        let policy = TabHibernationPolicy(manager: self)
        Self.policies[key] = policy
        return policy
    }

    /// Live web views, not tabs: a hibernated tab is still in the sidebar, it just has
    /// no `WKWebView` behind it any more.
    func liveWebViewCount(in containers: [TabContainer]? = nil) -> Int {
        let allContainers = containers ?? fetchContainers()
        return allContainers.reduce(0) { $0 + $1.tabs.filter(\.isWebViewReady).count }
    }

    /// Media playback vetoes an unload, unless the user asked for media tabs to go too.
    fileprivate func mayHibernate(_ tab: Tab) -> Bool {
        !tab.isPlayingMedia || SettingsStore.shared.unloadMediaTabs
    }

    /// A tab on screen in any window, not just this one. Managers are per window but the
    /// store is shared, so evicting on `activeTab` alone blanked the other window's page.
    func isActiveInAnyWindow(_ tab: Tab) -> Bool {
        tab.id == activeTab?.id || TabManager.activeTabIDsAcrossWindows.contains(tab.id)
    }

    /// Drops a tab's web view and keeps the row: URL, title, header colour, and the
    /// scroll offset all survive. Typing the user has not submitted vetoes the unload,
    /// so nothing typed is lost, and so does playback unless `unloadMediaTabs` is on.
    fileprivate func hibernate(_ tab: Tab) {
        guard tab.isWebViewReady, !isActiveInAnyWindow(tab), mayHibernate(tab) else { return }
        guard hibernating.insert(tab.id).inserted else { return }
        let id = tab.id
        tab.captureHibernationState { [weak self, weak tab] hasUnsavedInput in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hibernating.remove(id)
                // The probe is the only place unsaved input is ever observed, so the
                // score's memory of it is refreshed here.
                if hasUnsavedInput {
                    self.hibernationPolicy.tabsWithUnsavedInput.insert(id)
                } else {
                    self.hibernationPolicy.tabsWithUnsavedInput.remove(id)
                }
                // The probe is a round trip: the tab can have been selected, in this
                // window or another, while the answer was in flight.
                guard let tab, !hasUnsavedInput, self.mayHibernate(tab), !self.isActiveInAnyWindow(tab)
                else { return }
                tab.destroyWebView()
            }
        }
    }

    /// Clean up old tabs that haven't been accessed recently to preserve memory
    func cleanupOldTabs(in containers: [TabContainer]? = nil) {
        let timeout = SettingsStore.shared.tabAliveTimeout
        // Skip cleanup if set to "Never" (365 days)
        guard timeout < 365 * 24 * 60 * 60 else { return }

        let allContainers = containers ?? fetchContainers()
        for container in allContainers {
            for tab in container.tabs {
                if !tab.isAlive, tab.isWebViewReady, !isActiveInAnyWindow(tab), mayHibernate(tab),
                   tab.type == .normal
                {
                    hibernate(tab)
                }
            }
        }
    }

    /// A live `WKWebView` costs tens of megabytes in its own content process whether or
    /// not the tab is on screen, so the count is capped as well as the age: a tab well
    /// inside `tabAliveTimeout` still goes if enough other tabs were touched after it.
    /// Only normal tabs are evictable, matching `cleanupOldTabs`; pinned and favourite
    /// tabs are deliberately kept warm, so a wall of them can hold the count over the cap.
    func enforceLiveTabLimit(in containers: [TabContainer]? = nil) {
        let limit = SettingsStore.shared.maxLiveTabs
        guard limit > 0 else { return }

        let allContainers = containers ?? fetchContainers()
        let live = allContainers.flatMap(\.tabs).filter(\.isWebViewReady)
        let excess = live.count - limit
        guard excess > 0 else { return }

        // ponytail: plain sort over the live set, not a maintained LRU list. Switch to
        // an ordered structure if the live cap is ever raised past a few hundred.
        let evictable = live
            .filter { !isActiveInAnyWindow($0) && mayHibernate($0) && $0.type == .normal }
            .sorted { ($0.lastAccessedAt ?? .distantPast) < ($1.lastAccessedAt ?? .distantPast) }

        for tab in evictable.prefix(excess) {
            hibernate(tab)
        }
    }

    /// Completely remove old normal tabs that haven't been accessed for a long time
    func removeOldTabs(in containers: [TabContainer]? = nil) {
        let cutoffDate = Date().addingTimeInterval(-SettingsStore.shared.tabRemovalTimeout)
        let allContainers = containers ?? fetchContainers()

        for container in allContainers {
            // `closeTab` deletes from `container.tabs`, so the loop walks a copy.
            for tab in Array(container.tabs) {
                if let lastAccessed = tab.lastAccessedAt,
                   lastAccessed < cutoffDate,
                   !isActiveInAnyWindow(tab),
                   !tab.isPlayingMedia,
                   tab.type == .normal
                {
                    closeTab(tab: tab, shouldTrackForRestore: false)
                }
            }
        }
    }

    /// Remove tabs in containers that have a per-space autoClearTabsAfter setting
    func autoClearContainerTabs(in containers: [TabContainer]? = nil) {
        let settings = SettingsStore.shared
        let allContainers = containers ?? fetchContainers()

        for container in allContainers {
            let policy = settings.autoClearTabsAfter(for: container.id)
            guard let timeout = policy.seconds else { continue }

            let cutoffDate = Date().addingTimeInterval(-timeout)
            for tab in Array(container.tabs) {
                if let lastAccessed = tab.lastAccessedAt,
                   lastAccessed < cutoffDate,
                   !isActiveInAnyWindow(tab),
                   !tab.isPlayingMedia,
                   tab.type == .normal
                {
                    closeTab(tab: tab)
                }
            }
        }
    }

    /// Run all three tab-expiry passes off a single container fetch.
    func runTabMaintenance() {
        // ponytail: the pressure policy is armed from the first maintenance tick, up to
        // 60 s after launch, because `TabManager.init` is in another file. Move the call
        // into `init` if pressure inside that first minute ever matters.
        hibernationPolicy.arm()
        let containers = fetchContainers()
        cleanupOldTabs(in: containers)
        enforceLiveTabLimit(in: containers)
        removeOldTabs(in: containers)
        autoClearContainerTabs(in: containers)
    }
}
