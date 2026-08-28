import AppKit
import SwiftUI

struct FavTabsGrid: View {
    @Environment(TabManager.self) private var tabManager
    let tabs: [Tab]
    let zone: TabDragZone
    @ObservedObject private var dragSession = TabDragSession.shared
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

    /// The invisible strip matches the drop bar's height, so the bar appearing under
    /// the pointer replaces blank space one for one and the sidebar never shifts.
    private static let emptyHotStrip: CGFloat = 31

    var body: some View {
        LazyVGrid(columns: adaptiveColumns, spacing: 10) {
            if tabs.isEmpty {
                // The empty drop target reveals itself only under the pointer. A drag
                // in flight mounts an invisible strip above the space name — a zone
                // has to have area before it can be hovered — and the "drop here" bar
                // shows for as long as the tab is over it. Folder drags mount nothing:
                // a folder cannot become a favourite.
                if dragSession.isDraggingTab {
                    if dragSession.activeZone == zone {
                        EmptyFavTabItem(isTargeted: true)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: Self.emptyHotStrip)
                    }
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
                            TabDropIndicatorLine(axis: zone.axis)
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
