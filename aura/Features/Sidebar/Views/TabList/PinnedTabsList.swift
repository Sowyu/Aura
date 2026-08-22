import SwiftData
import SwiftUI

struct PinnedTabsList: View {
    let tabs: [Tab]
    let zone: TabDragZone
    let onSelect: (Tab) -> Void
    let onPinToggle: (Tab) -> Void
    let onFavoriteToggle: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onDuplicate: (Tab) -> Void
    let onMoveToContainer: (Tab, TabContainer) -> Void
    let containers: [TabContainer]
    @Environment(TabManager.self) private var tabManager
    @Environment(\.theme) var theme
    @ObservedObject private var dragSession = TabDragSession.shared

    var body: some View {
        LazyVStack(spacing: 8) {
            Text("Pinned")
                .font(.callout)
                .foregroundColor(theme.mutedForeground)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tabs.isEmpty {
                EmptyPinnedTabs()
            } else {
                ForEach(tabs) { tab in
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
                    .overlay(alignment: indicatorEdge(tab)) {
                        if dragSession.indicator(for: tab.id, in: zone) != nil {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                                .padding(.horizontal, 6)
                        }
                    }
                    .tabDragSource(id: tab.id, in: zone)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tabDropZone(zone)
    }

    private func indicatorEdge(_ tab: Tab) -> Alignment {
        dragSession.indicator(for: tab.id, in: zone)?.below == true ? .bottom : .top
    }
}
