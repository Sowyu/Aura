import AppKit
import SwiftUI

struct FavTabsGrid: View {
    @Environment(\.theme) var theme
    @Environment(TabManager.self) private var tabManager
    let tabs: [Tab]
    @Binding var draggedItem: UUID?
    let onDrag: (UUID) -> NSItemProvider
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
                if draggedItem != nil {
                    EmptyFavTabItem()
                        .onDrop(
                            of: [.text],
                            delegate: SectionDropDelegate(
                                items: tabs,
                                draggedItem: $draggedItem,
                                targetSection: .fav,
                                tabManager: tabManager
                            )
                        )
                        .transition(.opacity)
                }
            } else {
                ForEach(tabs) { tab in
                    FavTabItem(
                        tab: tab,
                        isSelected: tabManager.isActive(tab),
                        isDragging: draggedItem == tab.id,
                        onTap: { onSelect(tab) },
                        onFavoriteToggle: { onFavoriteToggle(tab) },
                        onClose: { onClose(tab) },
                        onDuplicate: { onDuplicate(tab) },
                        onMoveToContainer: { onMoveToContainer(tab, $0) },
                        containers: containers
                    )
                    .onDrag { onDrag(tab.id) }
                    .onDrop(
                        of: [.text],
                        delegate: TabDropDelegate(
                            item: tab,
                            draggedItem: $draggedItem
                        )
                    )
                }
            }
        }
        .animation(AnimationSettings.easeOut(0.1), value: adaptiveColumns.count)
        .animation(AnimationSettings.easeOut(0.12), value: draggedItem == nil)
        .onDrop(
            of: [.text],
            delegate: SectionDropDelegate(
                items: tabs,
                draggedItem: $draggedItem,
                targetSection: .fav,
                tabManager: tabManager
            )
        )
    }
}
