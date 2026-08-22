import SwiftData
import SwiftUI

// MARK: - Recently Closed Tabs

/// Everything a closed tab needs to come back: where it sat, what it showed, and which
/// folder it belonged to. A snapshot rather than the model object, because the row is
/// deleted from the store on close.
struct ClosedTabSnapshot {
    let id: UUID
    let containerID: UUID
    let url: URL
    let savedURL: URL?
    let title: String
    let favicon: URL?
    let faviconLocalFile: URL?
    let createdAt: Date
    let lastAccessedAt: Date?
    let type: TabType
    let order: Int
    /// The folder the tab sat in, so reopening puts it back inside it rather than at
    /// the top level.
    let folderID: UUID?
    let backgroundColorHex: String
    let isPrivate: Bool

    init(tab: Tab) {
        id = tab.id
        containerID = tab.container.id
        url = tab.url
        savedURL = tab.savedURL
        title = tab.title
        favicon = tab.favicon
        faviconLocalFile = tab.faviconLocalFile
        createdAt = tab.createdAt
        lastAccessedAt = tab.lastAccessedAt
        type = tab.type
        order = tab.order
        folderID = tab.folder?.id
        backgroundColorHex = tab.backgroundColorHex
        isPrivate = tab.isPrivate
    }
}

@MainActor
extension TabManager {
    func restoreLastTab() {
        guard let snapshot = recentlyClosedTabs.popLast() else { return }
        let container = fetchContainers()
            .first(where: { $0.id == snapshot.containerID }) ?? activeContainer ?? createContainer()

        shiftRestoredTabOrders(in: container, restoring: snapshot)

        let restoredTab = Tab(
            id: snapshot.id,
            url: snapshot.url,
            title: snapshot.title,
            favicon: snapshot.favicon,
            container: container,
            type: snapshot.type,
            order: snapshot.order,
            tabManager: self,
            isPrivate: snapshot.isPrivate
        )
        restoredTab.savedURL = snapshot.savedURL
        restoredTab.faviconLocalFile = snapshot.faviconLocalFile
        restoredTab.createdAt = snapshot.createdAt
        restoredTab.lastAccessedAt = snapshot.lastAccessedAt
        restoredTab.backgroundColorHex = snapshot.backgroundColorHex
        // A folder deleted since the tab was closed just means it comes back top level.
        if let folderID = snapshot.folderID {
            restoredTab.folder = container.folders.first { $0.id == folderID }
            restoredTab.folder?.isCollapsed = false
        }

        modelContext.insert(restoredTab)
        container.tabs.append(restoredTab)
        activateTab(restoredTab)
        try? modelContext.save()
    }

    func trackRecentlyClosedTab(_ tab: Tab) {
        recentlyClosedTabs.append(ClosedTabSnapshot(tab: tab))
        if recentlyClosedTabs.count > maxRecentlyClosedTabs {
            recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - maxRecentlyClosedTabs)
        }
    }

    func shiftRestoredTabOrders(in container: TabContainer, restoring snapshot: ClosedTabSnapshot) {
        for tab in container.tabs where tab.type == snapshot.type && tab.order >= snapshot.order {
            tab.order += 1
        }
        // Folders sit among the normal tabs and share `Tab.order`'s scale, so shifting only
        // the tabs left the restored tab sharing an order with a folder and the sidebar
        // resolved the tie however the fetch happened to come back.
        guard snapshot.type == .normal else { return }
        for folder in container.folders where folder.order >= snapshot.order {
            folder.order += 1
        }
    }
}
