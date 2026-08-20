import AppKit
import SwiftData
import SwiftUI

/// Dropping a tab on a folder row moves the tab into that folder.
struct FolderDropDelegate: DropDelegate {
    let folder: Folder
    @Binding var draggedItem: UUID?
    @Binding var dropTargetFolderID: UUID?
    let tabManager: TabManager

    func dropEntered(info: DropInfo) {
        dropTargetFolderID = folder.id
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        performHapticFeedback(pattern: .alignment)

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let uuid = UUID(uuidString: string)
            else { return }

            DispatchQueue.main.async {
                guard let tab = folder.container.tabs.first(where: { $0.id == uuid }) else { return }
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
