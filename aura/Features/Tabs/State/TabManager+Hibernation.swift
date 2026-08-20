import SwiftData
import SwiftUI

/// Tab hibernation: dropping a web view while keeping the tab. Two policies feed it,
/// an age cutoff (`tabAliveTimeout`) and a live-view cap (`tabs.maxLive`), and both
/// run off the single maintenance pass in `TabManager`.
@MainActor
extension TabManager {
    /// Live web views, not tabs: a hibernated tab is still in the sidebar, it just has
    /// no `WKWebView` behind it any more.
    func liveWebViewCount(in containers: [TabContainer]? = nil) -> Int {
        let allContainers = containers ?? fetchContainers()
        return allContainers.reduce(0) { $0 + $1.tabs.filter(\.isWebViewReady).count }
    }

    /// Drops a tab's web view and keeps the row: URL, title, header colour, and the
    /// scroll offset all survive. Media playback and typing the user has not submitted
    /// both veto the unload, so nothing audible stops and nothing typed is lost.
    private func hibernate(_ tab: Tab) {
        guard tab.isWebViewReady, tab.id != activeTab?.id, !tab.isPlayingMedia else { return }
        guard hibernating.insert(tab.id).inserted else { return }
        let id = tab.id
        tab.captureHibernationState { [weak self, weak tab] hasUnsavedInput in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hibernating.remove(id)
                guard let tab, !hasUnsavedInput, !tab.isPlayingMedia, tab.id != self.activeTab?.id else { return }
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
                if !tab.isAlive, tab.isWebViewReady, tab.id != activeTab?.id, !tab.isPlayingMedia, tab.type == .normal {
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
            .filter { $0.id != activeTab?.id && !$0.isPlayingMedia && $0.type == .normal }
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
            for tab in container.tabs {
                if let lastAccessed = tab.lastAccessedAt,
                   lastAccessed < cutoffDate,
                   tab.id != activeTab?.id,
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
            for tab in container.tabs {
                if let lastAccessed = tab.lastAccessedAt,
                   lastAccessed < cutoffDate,
                   tab.id != activeTab?.id,
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
        let containers = fetchContainers()
        cleanupOldTabs(in: containers)
        enforceLiveTabLimit(in: containers)
        removeOldTabs(in: containers)
        autoClearContainerTabs(in: containers)
    }
}
