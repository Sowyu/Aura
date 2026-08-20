import SwiftData
import SwiftUI

// MARK: - Tab Folders

@MainActor
extension TabManager {
    /// Highest `order` used by a space's tabs and folders. The sidebar sorts descending,
    /// so `topOrder + 1` puts a new item at the top of the list.
    private func topOrder(in container: TabContainer) -> Int {
        let tabMax = container.tabs.map(\.order).max() ?? 0
        let folderMax = container.folders.map(\.order).max() ?? 0
        return max(tabMax, folderMax)
    }

    @discardableResult
    func createFolder(name: String = "New Folder", in container: TabContainer? = nil) -> Folder? {
        guard let container = container ?? activeContainer else { return nil }
        let folder = Folder(name: name, order: topOrder(in: container) + 1, container: container)
        modelContext.insert(folder)
        try? modelContext.save()
        return folder
    }

    /// Creates a folder and puts the sidebar row straight into inline rename mode.
    func createFolderForRenaming() {
        guard let folder = createFolder() else { return }
        renamingFolderID = folder.id
    }

    func rename(folder: Folder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != folder.name else { return }
        folder.name = trimmed
        try? modelContext.save()
    }

    /// `closeTabs: false` keeps the tabs and drops them back to the top level.
    func delete(folder: Folder, closeTabs: Bool) {
        let tabs = Array(folder.tabs)
        for tab in tabs {
            tab.folder = nil
        }
        if renamingFolderID == folder.id {
            renamingFolderID = nil
        }
        modelContext.delete(folder)
        try? modelContext.save()

        if closeTabs {
            for tab in tabs {
                closeTab(tab: tab)
            }
        }
    }

    func closeAllTabs(in folder: Folder) {
        for tab in Array(folder.tabs) {
            closeTab(tab: tab)
        }
    }

    /// Moves a tab into `folder`, or back to the top level when `folder` is nil.
    func move(tab: Tab, to folder: Folder?) {
        guard tab.folder?.id != folder?.id else { return }
        // A folder only ever holds tabs from its own space.
        if let folder, folder.container.id != tab.container.id { return }
        if folder != nil, tab.type != .normal {
            tab.type = .normal
            tab.savedURL = nil
        }
        tab.folder = folder
        // Dropping into a collapsed folder would hide the tab you just moved.
        folder?.isCollapsed = false
        try? modelContext.save()
    }

    func toggleCollapsed(_ folder: Folder) {
        folder.isCollapsed.toggle()
        try? modelContext.save()
    }

    /// Opens a new tab already inside `folder`.
    func addTab(
        in folder: Folder,
        historyManager: HistoryManager? = nil,
        downloadManager: DownloadManager? = nil,
        isPrivate: Bool
    ) {
        let tab = addTab(
            container: folder.container,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: isPrivate
        )
        move(tab: tab, to: folder)
    }
}
