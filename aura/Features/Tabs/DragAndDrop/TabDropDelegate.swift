import AppKit
import SwiftData
import SwiftUI

/// Where a dragged row will land: on the top or bottom edge of `targetID`'s row.
struct TabDropIndicator: Equatable {
    let targetID: UUID
    let below: Bool
}

/// Nothing moves while the pointer is down. Hovering a row only places the indicator
/// line on its upper or lower half; the reorder happens once on release.
struct TabDropDelegate: DropDelegate {
    /// The row being dropped on.
    let item: Tab
    @Binding var draggedItem: UUID?
    @Binding var dropIndicator: TabDropIndicator?
    /// Row height, so the pointer's half decides above/below.
    var rowHeight: CGFloat = 40

    func dropEntered(info: DropInfo) {
        guard draggedItem != nil, draggedItem != item.id else { return }
        performHapticFeedback(pattern: .alignment)
        dropIndicator = TabDropIndicator(targetID: item.id, below: info.location.y > rowHeight / 2)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if draggedItem != nil, draggedItem != item.id {
            let next = TabDropIndicator(targetID: item.id, below: info.location.y > rowHeight / 2)
            if next != dropIndicator { dropIndicator = next }
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.targetID == item.id { dropIndicator = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let indicator = dropIndicator
        defer {
            dropIndicator = nil
            draggedItem = nil
        }
        guard let uuid = draggedItem, uuid != item.id else { return false }

        var from = item.container.tabs.first(where: { $0.id == uuid })
        if from == nil, let context = item.modelContext {
            let descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == uuid })
            from = try? context.fetch(descriptor).first
        }
        guard let from else { return false }

        // A tab dragged in from another space has to change space first,
        // otherwise it kept rendering in the one it came from.
        if from.container.id != item.container.id {
            from.folder = nil
            from.container = item.container
        }

        if isInSameSection(from: from, to: item) {
            // A tab dropped next to another one joins that tab's folder, which is
            // also how a child leaves a folder: the target is top level.
            if from.type == .normal, from.folder?.id != item.folder?.id {
                from.folder = item.folder
                item.folder?.isCollapsed = false
            }
            withAnimation(AnimationSettings.easeOut(0.15)) {
                item.container.reorderTabs(from: from, to: item, placeBelow: indicator?.below)
            }
            try? item.modelContext?.save()
        } else {
            moveTabBetweenSections(from: from, to: item)
        }
        return true
    }
}
