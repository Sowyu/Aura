import SwiftUI

struct NormalTabsList: View {
    /// Top-level normal tabs, already sorted. Tabs inside folders are not in here.
    let tabs: [Tab]
    let folders: [Folder]
    let zone: TabDragZone
    let onSelect: (Tab) -> Void
    let onPinToggle: (Tab) -> Void
    let onFavoriteToggle: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onDuplicate: (Tab) -> Void
    let onMoveToContainer:
        (
            Tab,
            TabContainer
        ) -> Void
    let onAddNewTab: () -> Void
    let onNewTabInFolder: (Folder) -> Void
    /// Passed down rather than fetched here: a second SwiftData query in this view
    /// re-ran, and rebuilt every row, on any change to any space.
    let containers: [TabContainer]
    @Environment(TabManager.self) private var tabManager
    @ObservedObject private var dragSession = TabDragSession.shared
    @State private var previousTabIds: [UUID] = []

    /// Folders and top-level tabs share one `order` scale, so they interleave.
    private enum Row: Identifiable {
        case tab(Tab)
        case folder(Folder)

        var id: UUID {
            switch self {
            case let .tab(tab): return tab.id
            case let .folder(folder): return folder.id
            }
        }

        var order: Int {
            switch self {
            case let .tab(tab): return tab.order
            case let .folder(folder): return folder.order
            }
        }
    }

    private var rows: [Row] {
        (tabs.map(Row.tab) + folders.map(Row.folder)).sorted { $0.order > $1.order }
    }

    var body: some View {
        // Lazy: switching tabs re-reads `tabManager.activeTab` here, so a plain stack
        // rebuilt every row in the space on every switch.
        LazyVStack(spacing: 8) {
            NewTabButton(addNewTab: onAddNewTab)
            ForEach(rows) { row in
                switch row {
                case let .tab(tab):
                    tabRow(tab)
                case let .folder(folder):
                    folderRow(folder)
                }
            }
        }
        .tabDropZone(zone)
        .onAppear {
            previousTabIds = tabs.map(\.id)
        }
        .onChange(of: tabs.map(\.id)) { _, newTabIds in
            previousTabIds = newTabIds
        }
    }

    @ViewBuilder
    private func tabRow(_ tab: Tab) -> some View {
        TabItem(
            tab: tab,
            isSelected: tabManager.isActive(tab),
            isDragging: dragSession.draggedID == tab.id,
            onTap: { onSelect(tab) },
            onPinToggle: { onPinToggle(tab) },
            onFavoriteToggle: { onFavoriteToggle(tab) },
            onClose: { onClose(tab) },
            onDuplicate: { onDuplicate(tab) },
            onMoveToContainer: { onMoveToContainer(tab, $0) },
            availableContainers: containers
        )
        .overlay(alignment: dragSession.indicator(for: tab.id, in: zone)?.below == true ? .bottom : .top) {
            if dragSession.indicator(for: tab.id, in: zone) != nil {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .tabDragSource(id: tab.id, in: zone)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity.combined(with: .move(edge: .top))
        ))
        .animation(AnimationSettings.easeOut(0.15), value: shouldAnimate(tab))
    }

    @ViewBuilder
    private func folderRow(_ folder: Folder) -> some View {
        VStack(spacing: 8) {
            FolderItem(
                folder: folder,
                isDropTarget: dragSession.isFolderTarget(folder.id),
                onToggle: { tabManager.toggleCollapsed(folder) },
                onNewTab: { onNewTabInFolder(folder) },
                onCloseTabs: { tabManager.closeAllTabs(in: folder) },
                onDelete: { tabManager.delete(folder: folder, closeTabs: $0) }
            )
            .tabDragSource(id: folder.id, isFolder: true, in: zone)
            .overlay(alignment: dragSession.indicator(for: folder.id, in: zone)?.below == true ? .bottom : .top) {
                if dragSession.indicator(for: folder.id, in: zone) != nil {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                }
            }

            if !folder.isCollapsed {
                ForEach(folder.sortedTabs) { tab in
                    tabRow(tab)
                        .padding(.leading, 16)
                }
            }
        }
        .animation(AnimationSettings.easeOut(0.12), value: folder.isCollapsed)
    }

    private func shouldAnimate(_ tab: Tab) -> Bool {
        // Only animate if the tab's position has actually changed
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tab.id }),
              let previousIndex = previousTabIds.firstIndex(where: { $0 == tab.id })
        else {
            return true // Animate new tabs or tabs that were just created
        }
        return currentIndex != previousIndex
    }
}
