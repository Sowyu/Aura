import AppKit
import SwiftData
import SwiftUI

struct TabDropDelegate: DropDelegate {
    /// The row being dropped on.
    let item: Tab
    @Binding var draggedItem: UUID?

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        performHapticFeedback(pattern: .alignment)
        provider.loadObject(ofClass: NSString.self) { object, _ in
            if let string = object as? String,
               let uuid = UUID(uuidString: string)
            {
                DispatchQueue.main.async {
                    // First try to find the tab in the target container
                    var from = self.item.container.tabs.first(where: { $0.id == uuid })

                    // If not found, look it up across all containers (drag from another space)
                    if from == nil, let context = self.item.modelContext {
                        let descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == uuid })
                        from = try? context.fetch(descriptor).first
                    }

                    guard let from, from.id != self.item.id else { return }

                    // A tab dragged in from another space has to change space first,
                    // otherwise it kept rendering in the one it came from.
                    if from.container.id != self.item.container.id {
                        from.folder = nil
                        from.container = self.item.container
                    }

                    if isInSameSection(
                        from: from,
                        to: self.item
                    ) {
                        // A tab dropped next to another one joins that tab's folder,
                        // which is also how a child leaves a folder: the target is top level.
                        if from.type == .normal, from.folder?.id != self.item.folder?.id {
                            from.folder = self.item.folder
                            self.item.folder?.isCollapsed = false
                        }
                        withAnimation(AnimationSettings.easeOut(0.15)) {
                            self.item.container
                                .reorderTabs(
                                    from: from,
                                    to: self.item
                                )
                        }
                        try? self.item.modelContext?.save()
                    } else {
                        moveTabBetweenSections(from: from, to: self.item)
                    }
                }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        .init(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}
