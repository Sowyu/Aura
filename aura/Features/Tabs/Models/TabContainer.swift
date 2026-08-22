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

    /// Moves `from` next to `to` inside the group they share: same section, same folder.
    /// The group's existing `order` values are dealt back out in the new arrangement,
    /// so the set of values is unchanged and no two rows can end up with the same one.
    /// `placeBelow` pins the landing side when the caller knows it (a drop indicator);
    /// nil keeps the drag-direction heuristic.
    func reorderTabs(from: Tab, to: Tab, placeBelow: Bool? = nil) {
        // Callers that cross sections (`moveTabBetweenSections`) retype the tab first.
        guard from.id != to.id, from.type == to.type else { return }
        var group = tabs
            .filter { $0.type == to.type && $0.folder?.id == to.folder?.id && $0.id != from.id }
            .sorted { $0.order > $1.order }
        guard let targetIndex = group.firstIndex(where: { $0.id == to.id }) else { return }

        // The sidebar sorts descending, so a tab above the target (higher order) is
        // being dragged down past it and lands below.
        let movingDown = placeBelow ?? (from.order > to.order)
        var values = group.map(\.order)
        values.append(from.order)
        values.sort(by: >)

        group.insert(from, at: movingDown ? targetIndex + 1 : targetIndex)
        for (index, tab) in group.enumerated() {
            tab.order = values[index]
        }
    }
}
