import Foundation
import SwiftData

// MARK: - Folder

/// A group of normal tabs inside one space. Folders sit among the top-level tabs in the
/// sidebar and share `Tab.order`'s scale, so the list sorts both together.
@Model
class Folder: ObservableObject, Identifiable {
    var id: UUID
    var name: String
    var order: Int = 0
    var isCollapsed: Bool = false

    @Relationship(inverse: \TabContainer.folders) var container: TabContainer
    /// Nullify, never cascade: deleting a folder must not take its tabs with it.
    @Relationship(deleteRule: .nullify, inverse: \Tab.folder) var tabs: [Tab] = []

    init(
        id: UUID = UUID(),
        name: String,
        order: Int = 0,
        isCollapsed: Bool = false,
        container: TabContainer
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.isCollapsed = isCollapsed
        self.container = container
    }

    /// Only normal tabs render inside a folder; pinning or favouriting a tab pulls it out.
    var sortedTabs: [Tab] {
        tabs.filter { $0.type == .normal }.sorted { $0.order > $1.order }
    }
}
