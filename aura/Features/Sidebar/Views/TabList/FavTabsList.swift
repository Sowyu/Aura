import AppKit
import SwiftUI

struct FavTabsGrid: View {
    @Environment(\.theme) var theme
    @Environment(TabManager.self) private var tabManager
    let tabs: [Tab]
    let zone: TabDragZone
    @ObservedObject private var dragSession = TabDragSession.shared
    let selectedContainerId: String
    let onSelect: (Tab) -> Void
    let onFavoriteToggle: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onDuplicate: (Tab) -> Void
    let onMoveToContainer:
        (
            Tab,
            TabContainer
        ) -> Void
    let containers: [TabContainer]

    private var adaptiveColumns: [GridItem] {
        let maxColumns = 3
        let columnCount = min(max(1, tabs.count), maxColumns)
        return Array(repeating: GridItem(spacing: 10), count: columnCount)
    }

    var body: some View {
        LazyVGrid(columns: adaptiveColumns, spacing: 10) {
            if tabs.isEmpty {
                // Only a live tab drag reveals the drop zone; otherwise it is sidebar clutter.
                if dragSession.isDragging {
                    EmptyFavTabItem()
                }
            } else {
                ForEach(tabs) { tab in
                    FavTabItem(
                        tab: tab,
                        isSelected: tabManager.isActive(tab),
                        isDragging: dragSession.draggedID == tab.id,
                        onTap: { onSelect(tab) },
                        onFavoriteToggle: { onFavoriteToggle(tab) },
                        onClose: { onClose(tab) },
                        onDuplicate: { onDuplicate(tab) },
                        onMoveToContainer: { onMoveToContainer(tab, $0) },
                        containers: containers
                    )
                    .overlay(alignment: indicatorEdge(tab)) {
                        // The grid runs left to right, so the line stands on a side edge.
                        if dragSession.indicator(for: tab.id, in: zone) != nil {
                            Capsule()
                                .fill(theme.accent)
                                .frame(width: 2)
                                .padding(.vertical, 4)
                        }
                    }
                    .tabDragSource(
                        id: tab.id,
                        in: zone,
                        url: tab.url,
                        title: tab.title,
                        onMiddleClick: { onClose(tab) }
                    )
                }
            }
        }
        .animation(AnimationSettings.easeOut(0.1), value: adaptiveColumns.count)
        .tabDropZone(zone)
    }

    private func indicatorEdge(_ tab: Tab) -> Alignment {
        dragSession.indicator(for: tab.id, in: zone)?.below == true ? .trailing : .leading
    }
}
