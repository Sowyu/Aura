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

    /// Entering only highlights the folder. Moving on enter meant a tab dragged *past*
    /// a folder on its way somewhere else was pulled into it, then out, then in again.
    func dropEntered(info: DropInfo) {
        guard draggedItem != nil, draggedItem != folder.id else { return }
        performHapticFeedback(pattern: .alignment)
        dropTargetFolderID = folder.id
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
        defer {
            dropTargetFolderID = nil
            draggedItem = nil
        }
        guard let uuid = draggedItem, uuid != folder.id else { return false }
        if let dragged = folder.container.folders.first(where: { $0.id == uuid }) {
            withAnimation(AnimationSettings.easeOut(0.15)) {
                tabManager.move(folder: dragged, to: folder)
            }
            return true
        }
        guard let tab = folder.container.tabs.first(where: { $0.id == uuid }) else { return false }
        withAnimation(AnimationSettings.easeOut(0.15)) {
            tabManager.move(tab: tab, to: folder)
        }
        return true
    }
}
