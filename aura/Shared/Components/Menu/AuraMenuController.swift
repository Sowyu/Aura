import AppKit
import SwiftUI

/// Where a menu hangs off. Both cases are read in AppKit window coordinates.
enum AuraMenuAnchor {
    /// Top-left corner sits on the point, flipping left/up near an edge.
    case point
    /// Top-left corner sits just under the rect, flipping above it near the bottom edge.
    case below(CGRect)
}

/// Fixed geometry for every Aura menu. Rows have known heights, so a panel can be placed
/// and hit-tested without measuring anything — that is what lets a menu appear in one frame.
enum AuraMenuMetrics {
    /// Floor for every panel, and the width a menu of short labels keeps.
    static let width: CGFloat = 240
    /// Ceiling, so one pathological title cannot stretch a panel across the window.
    static let maxWidth: CGFloat = 420
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 22
    static let separatorHeight: CGFloat = 9
    static let verticalPadding: CGFloat = 6
    static let panelRadius: CGFloat = 10
    static let itemRadius: CGFloat = 6
    static let iconSize: CGFloat = 16
    static let leadingInset: CGFloat = 10
    /// Gap kept between a panel and the window edge, and between a submenu and its parent.
    static let windowInset: CGFloat = 8
    static let submenuOverlap: CGFloat = 4

    static func height(of item: AuraMenuItem) -> CGFloat {
        switch item.kind {
        case .separator: separatorHeight
        case .header: headerHeight
        case .item, .submenu: rowHeight
        }
    }

    static func height(of items: [AuraMenuItem]) -> CGFloat {
        items.reduce(verticalPadding * 2) { $0 + height(of: $1) }
    }

    private static let titleFont = NSFont.systemFont(ofSize: 13)
    private static let shortcutFont = NSFont.systemFont(ofSize: 12)
    /// Row padding, icon slot, the gaps around them, and room for a submenu chevron.
    private static let rowChrome: CGFloat = 10 + iconSize + 8 + 6 + 17 + 10

    /// Widest row, clamped. A fixed 240pt panel middle-truncated real titles such as
    /// "Always Open example.com in This Space" into unreadable stubs.
    static func width(of items: [AuraMenuItem]) -> CGFloat {
        let widest = items.reduce(CGFloat.zero) { widest, item in
            let title = (item.title as NSString)
                .size(withAttributes: [.font: item.kind == .header ? shortcutFont : titleFont]).width
            let shortcut = item.shortcut.map {
                ($0 as NSString).size(withAttributes: [.font: shortcutFont]).width
            } ?? 0
            return max(widest, title + shortcut)
        }
        return min(max(width, (widest + rowChrome).rounded(.up)), maxWidth)
    }

    /// Distance from the panel's top edge to the top of `index`.
    static func offset(ofRow index: Int, in items: [AuraMenuItem]) -> CGFloat {
        items.prefix(index).reduce(verticalPadding) { $0 + height(of: $1) }
    }

    /// Row under a y offset measured from the panel's top edge, or nil in the padding.
    static func row(atOffset offset: CGFloat, in items: [AuraMenuItem]) -> Int? {
        var top = verticalPadding
        for (index, item) in items.enumerated() {
            let bottom = top + height(of: item)
            if offset >= top, offset < bottom {
                return index
            }
            top = bottom
        }
        return nil
    }
}

/// Presents and drives every in-app menu. One instance backs all windows; `window`
/// records which one owns the open menu so the other hosts stay empty.
@MainActor
final class AuraMenuController: ObservableObject {
    static let shared = AuraMenuController()

    /// One open panel. `levels[0]` is the root; hovering or clicking a submenu pushes another.
    struct Level: Identifiable {
        let id = UUID()
        var items: [AuraMenuItem]
        /// Top-left corner in SwiftUI (top-down) window coordinates.
        var origin: CGPoint
        var size: CGSize
        var highlighted: Int?
        var pressed: Int?
        /// Row of the parent level that opened this one.
        var parentRow: Int?

        var frame: CGRect {
            CGRect(origin: origin, size: size)
        }
    }

    @Published private(set) var levels: [Level] = []
    private(set) weak var window: NSWindow?

    var isOpen: Bool { !levels.isEmpty }

    // MARK: - Presenting

    /// `point` and any anchor rect are in AppKit window coordinates, which is what
    /// `NSEvent.locationInWindow` and `NSView.convert(_:to: nil)` hand back.
    func present(
        _ items: [AuraMenuItem],
        at point: CGPoint,
        anchor: AuraMenuAnchor = .point,
        in window: NSWindow? = nil
    ) {
        let tidyItems = items.tidied()
        guard let target = window ?? NSApp.keyWindow,
              let content = target.contentView,
              !tidyItems.isEmpty
        else {
            return
        }

        let bounds = content.bounds
        // ponytail: a menu taller than the window is clipped rather than scrolled. Give the
        // panel a ScrollView if any real menu ever outgrows a window.
        let size = CGSize(
            width: AuraMenuMetrics.width(of: tidyItems),
            height: min(AuraMenuMetrics.height(of: tidyItems), bounds.height - AuraMenuMetrics.windowInset * 2)
        )

        let desired: CGPoint
        let flipped: CGPoint
        switch anchor {
        case .point:
            let top = CGPoint(x: point.x, y: bounds.height - point.y)
            desired = top
            flipped = CGPoint(x: top.x - size.width, y: top.y - size.height)
        case let .below(rect):
            let top = CGRect(
                x: rect.minX,
                y: bounds.height - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            desired = CGPoint(x: top.minX, y: top.maxY + 4)
            flipped = CGPoint(x: top.maxX - size.width, y: top.minY - size.height - 4)
        }

        self.window = target
        // Mouse-moved events drive the highlight, and windows do not deliver them by default.
        target.acceptsMouseMovedEvents = true
        levels = [
            Level(
                items: tidyItems,
                origin: place(desired, flippingTo: flipped, size: size, in: bounds),
                size: size
            )
        ]
    }

    func dismiss() {
        guard isOpen else { return }
        levels = []
        window = nil
    }

    /// Keeps a panel inside the window by flipping it rather than sliding it, so the
    /// anchor the user clicked stays uncovered.
    private func place(
        _ desired: CGPoint,
        flippingTo flipped: CGPoint,
        size: CGSize,
        in bounds: CGRect
    ) -> CGPoint {
        let inset = AuraMenuMetrics.windowInset
        var left = desired.x
        if left + size.width > bounds.maxX - inset {
            left = flipped.x
        }
        var top = desired.y
        if top + size.height > bounds.maxY - inset {
            top = flipped.y
        }
        return CGPoint(
            x: min(max(inset, left), max(inset, bounds.maxX - inset - size.width)),
            y: min(max(inset, top), max(inset, bounds.maxY - inset - size.height))
        )
    }
}

// MARK: - Navigation

extension AuraMenuController {
    var deepest: Int { levels.count - 1 }

    func item(atLevel level: Int, row: Int) -> AuraMenuItem? {
        guard levels.indices.contains(level), levels[level].items.indices.contains(row) else { return nil }
        return levels[level].items[row]
    }

    func highlight(row: Int?, atLevel level: Int) {
        guard levels.indices.contains(level), levels[level].highlighted != row else { return }
        levels[level].highlighted = row
    }

    func press(row: Int?, atLevel level: Int) {
        guard levels.indices.contains(level) else { return }
        levels[level].pressed = row
    }

    /// Drops every panel deeper than `level`.
    func closeLevels(deeperThan level: Int) {
        guard levels.count > level + 1, level >= 0 else { return }
        levels.removeSubrange((level + 1)...)
    }

    @discardableResult
    func openSubmenu(atLevel level: Int, row: Int) -> Bool {
        guard let parent = item(atLevel: level, row: row), parent.kind == .submenu, !parent.isDisabled,
              let content = window?.contentView
        else {
            return false
        }
        if levels.count > level + 1, levels[level + 1].parentRow == row {
            return true
        }
        closeLevels(deeperThan: level)

        let bounds = content.bounds
        let items = parent.items
        let size = CGSize(
            width: AuraMenuMetrics.width(of: items),
            height: min(AuraMenuMetrics.height(of: items), bounds.height - AuraMenuMetrics.windowInset * 2)
        )
        let panel = levels[level].frame
        let rowTop = panel.minY + AuraMenuMetrics.offset(ofRow: row, in: levels[level].items)
        let overlap = AuraMenuMetrics.submenuOverlap
        // The child's first row lines up with the parent row; near an edge it flips to the
        // left of the parent panel, and upwards so its bottom sits level with the parent's.
        let desired = CGPoint(x: panel.maxX - overlap, y: rowTop - AuraMenuMetrics.verticalPadding)
        let flipped = CGPoint(x: panel.minX - size.width + overlap, y: panel.maxY - size.height)

        levels.append(
            Level(
                items: items,
                origin: place(desired, flippingTo: flipped, size: size, in: bounds),
                size: size,
                parentRow: row
            )
        )
        return true
    }

    func moveHighlight(by delta: Int) {
        let level = deepest
        guard levels.indices.contains(level) else { return }
        let items = levels[level].items
        guard items.contains(where: \.isSelectable) else { return }

        var index = levels[level].highlighted ?? (delta > 0 ? -1 : items.count)
        for _ in 0..<items.count {
            index = (index + delta + items.count) % items.count
            if items[index].isSelectable {
                levels[level].highlighted = index
                return
            }
        }
    }

    /// Type-select: jumps to the next row whose title starts with `character`.
    func selectFirst(matching character: Character) {
        let level = deepest
        guard levels.indices.contains(level) else { return }
        let items = levels[level].items
        guard !items.isEmpty else { return }
        let needle = String(character).lowercased()
        let start = levels[level].highlighted ?? -1

        for step in 1...items.count {
            let index = (start + step + items.count) % items.count
            guard items[index].isSelectable, items[index].title.lowercased().hasPrefix(needle) else { continue }
            levels[level].highlighted = index
            return
        }
    }

    /// Runs the row's action, or opens it when it is a submenu. Closes the menu either way.
    func activate(level: Int, row: Int) {
        guard let target = item(atLevel: level, row: row), !target.isDisabled else { return }
        if target.kind == .submenu {
            if openSubmenu(atLevel: level, row: row) {
                levels[level + 1].highlighted = target.items.firstIndex(where: \.isSelectable)
            }
            return
        }
        guard let action = target.action else { return }
        dismiss()
        action()
    }

    /// Deepest panel and row under a point in SwiftUI window coordinates, if any.
    func hit(_ point: CGPoint) -> (level: Int, row: Int?)? {
        for level in levels.indices.reversed() where levels[level].frame.contains(point) {
            let offset = point.y - levels[level].origin.y
            return (level, AuraMenuMetrics.row(atOffset: offset, in: levels[level].items))
        }
        return nil
    }
}
