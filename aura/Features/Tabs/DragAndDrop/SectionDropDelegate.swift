import AppKit
import SwiftUI

struct SectionDropDelegate: DropDelegate {
    let items: [Tab]
    @Binding var draggedItem: UUID?
    let targetSection: TabSection
    let tabManager: TabManager

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        performHapticFeedback(pattern: .alignment)

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard
                let string = object as? String,
                let uuid = UUID(uuidString: string)
            else { return }

            DispatchQueue.main.async {
                guard let container = self.items.first?.container ?? self.tabManager.activeContainer,
                      let from = container.tabs.first(where: { $0.id == uuid })
                else { return }

                if self.items.isEmpty {
                    // Section is empty, just change type and order
                    let newType = tabType(for: self.targetSection)
                    from.type = newType
                    // Update savedURL when moving into pinned/fav; clear when moving to normal
                    switch newType {
                    case .pinned, .fav:
                        from.savedURL = from.url
                        // Only normal tabs live in folders.
                        from.folder = nil
                    case .normal:
                        from.savedURL = nil
                    }
                    let orders = container.tabs.map(\.order) + container.folders.map(\.order)
                    from.order = (orders.max() ?? 0) + 1
                    try? self.tabManager.modelContext.save()
                }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}
