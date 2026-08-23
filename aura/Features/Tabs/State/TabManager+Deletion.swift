import SwiftData
import SwiftUI

/// Deleting a tab or a space, and putting the other windows straight afterwards.
///
/// Every window runs its own `TabManager` over one shared store, so a delete here is
/// invisible to the rest of the app until `.tabsDeleted` says otherwise, and a row this
/// context is about to remove can already be gone from another one.
@MainActor
extension TabManager {
    /// Deletes a row only if the store still has it. Two windows run their own contexts
    /// over the same file, so a maintenance pass here can be looking at a tab the other
    /// window already removed, and deleting the same row twice is undefined behaviour.
    ///
    /// ponytail: one count query per row. Batch the check if a space is ever expected to
    /// hold thousands of tabs.
    @discardableResult
    func deleteIfPresent(_ tab: Tab) -> Bool {
        guard !tab.isDeleted else { return false }
        let id = tab.id
        var descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        // A failed count is treated as "still there": the alternative is silently
        // skipping a delete the user asked for.
        guard ((try? modelContext.fetchCount(descriptor)) ?? 1) > 0 else { return false }
        modelContext.delete(tab)
        return true
    }

    /// What the reconcile needs to know about the active tab, copied while its row is
    /// still live. Once another window has deleted the row, reading any stored property
    /// off the model traps inside SwiftData, and `isDeleted` does not cover a delete made
    /// by another context, so nothing below may touch the instance itself.
    struct TabPosition {
        let id: UUID
        let containerID: UUID
        let folderID: UUID?
        let type: TabType
        let order: Int

        init(_ tab: Tab) {
            id = tab.id
            containerID = tab.container.id
            folderID = tab.folder?.id
            type = tab.type
            order = tab.order
        }
    }

    /// Drops every trace of tabs another window deleted and moves the selection off a
    /// row that is no longer in the store.
    func reconcileDeletedTabs(_ ids: Set<UUID>) {
        hibernating.subtract(ids)
        hibernationPolicy.tabsWithUnsavedInput.subtract(ids)
        recentlyClosedTabs.removeAll { ids.contains($0.id) }

        guard let position = activePosition else {
            reselectContainerIfDeleted()
            return
        }
        guard ids.contains(position.id) else { return }

        let replacement = replacementTab(after: position)
        // No `maybeIsActive = false` on the way out: that would write to a deleted row.
        activeTab = nil
        if let replacement {
            activateTab(replacement)
        } else {
            reselectContainerIfDeleted()
        }
    }

    /// Where the selection falls when the active tab is deleted from under this window:
    /// the neighbour rule `closeTab` uses, then the space's most recent tab, then anything
    /// left anywhere. Every candidate comes from a fetch, which only returns rows that
    /// still exist, never from a cached relationship that may still hold the deleted one.
    func replacementTab(after position: TabPosition) -> Tab? {
        let sameSpace = fetchLiveTabs(in: position.containerID)
        let siblings = sameSpace
            .filter { $0.type == position.type && $0.folder?.id == position.folderID }
            .sorted { $0.order > $1.order }
        if let below = siblings.first(where: { $0.order < position.order }) { return below }
        if let above = siblings.last(where: { $0.order > position.order }) { return above }
        let pool = sameSpace.isEmpty ? fetchLiveTabs(in: nil) : sameSpace
        return pool.max { ($0.lastAccessedAt ?? .distantPast) < ($1.lastAccessedAt ?? .distantPast) }
    }

    private func fetchLiveTabs(in spaceID: UUID?) -> [Tab] {
        var descriptor = FetchDescriptor<Tab>()
        if let spaceID {
            descriptor.predicate = #Predicate { $0.container.id == spaceID }
        }
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// A space deleted in another window leaves this one pointing at a row that is gone.
    func reselectContainerIfDeleted() {
        guard let container = activeContainer, container.isDeleted else { return }
        activeContainer = fetchContainers().first { !$0.isDeleted }
    }

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

    /// Returns the ids it removed, so the caller can tell the other windows once the
    /// deletions are saved.
    @discardableResult
    func deleteContainerContents(_ container: TabContainer, containerId: UUID) -> [UUID] {
        var deleted: [UUID] = []
        for tab in Array(container.tabs) {
            if tab.isWebViewReady {
                tab.destroyWebView()
            }
            mediaController.removeSession(for: tab.id)
            // WebKit tracks open tabs by adapter object. A bulk delete never reached
            // `closeTab`, so the adapters outlived the rows and `tabs.query` kept
            // reporting tabs a deleted space had taken with it.
            ExtensionManager.shared.tabDidClose(tab)
            let id = tab.id
            if deleteIfPresent(tab) { deleted.append(id) }
        }

        for folder in Array(container.folders) where !folder.isDeleted {
            modelContext.delete(folder)
        }

        for history in fetchHistory(for: containerId) where !history.isDeleted {
            modelContext.delete(history)
        }
        return deleted
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
