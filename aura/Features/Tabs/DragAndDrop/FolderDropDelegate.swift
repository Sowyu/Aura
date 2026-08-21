import AppKit
import SwiftData
import SwiftUI

/// Dropping a tab on a folder row moves the tab into that folder; dropping another
/// folder on it reorders the two.
struct FolderDropDelegate: DropDelegate {
    let folder: Folder
    @Binding var draggedItem: UUID?
    @Binding var dropTargetFolderID: UUID?
    let tabManager: TabManager

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        performHapticFeedback(pattern: .alignment)

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let uuid = UUID(uuidString: string),
                  uuid != folder.id
            else { return }

            DispatchQueue.main.async {
                if let dragged = folder.container.folders.first(where: { $0.id == uuid }) {
                    withAnimation(AnimationSettings.easeOut(0.15)) {
                        tabManager.move(folder: dragged, to: folder)
                    }
                    return
                }
                guard let tab = folder.container.tabs.first(where: { $0.id == uuid }) else { return }
                dropTargetFolderID = folder.id
                tabManager.move(tab: tab, to: folder)
            }
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetFolderID == folder.id {
            dropTargetFolderID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetFolderID = nil
        draggedItem = nil
        return true
    }
}
