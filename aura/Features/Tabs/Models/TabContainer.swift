import Foundation
import SwiftData

// MARK: - TabContainer

@Model
class TabContainer: ObservableObject, Identifiable {
    var id: UUID
    var name: String
    var emoji: String
    /// SF Symbol name when the space uses an icon instead of an emoji.
    var iconSymbol: String?
    /// Tint for `iconSymbol`; `nil` means follow the theme foreground.
    var iconColorHex: String?
    var createdAt: Date
    var lastAccessedAt: Date

    @Relationship(deleteRule: .cascade) var tabs: [Tab] = []
    @Relationship(deleteRule: .cascade) var folders: [Folder] = []
    @Relationship var history: [History] = []

    init(
        id: UUID = UUID(),
        name: String = "Default",
        isActive: Bool = true,
        emoji: String = "💩",
        iconSymbol: String? = nil,
        iconColorHex: String? = nil
    ) {
        let nowDate = Date()
        self.id = id
        self.name = name
        self.emoji = emoji
        self.iconSymbol = iconSymbol
        self.iconColorHex = iconColorHex
        self.createdAt = nowDate
        self.lastAccessedAt = nowDate
    }

    func reorderTabs(from: Tab, to: Tab) {
        let dir = from.order - to.order > 0 ? -1 : 1

        let tabOrder = self.tabs.sorted { dir == -1 ? $0.order > $1.order : $0.order < $1.order }

        var started = false
        for (index, tab) in tabOrder.enumerated() {
            if tab.id == from.id {
                started = true
            }
            if tab.id == to.id {
                break
            }
            if started {
                let currentTab = tab
                let nextTab = tabOrder[index + 1]

                let tempOrder = currentTab.order
                currentTab.order = nextTab.order
                nextTab.order = tempOrder
            }
        }
    }
}
