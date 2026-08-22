//
//  TabDropResolver.swift
//  Aura
//
//  The position computation from Nook's NookDragSessionManager.updateInsertionIndex
//  (github.com/nook-browser/nook, GPL-3.0), rewritten for rows of unequal height.
//

import Foundation

/// Turns a pointer position into the drop it would make. Nook divides the pointer offset
/// by a fixed cell height to get an insertion index, which Aura cannot do: a folder row
/// carries its open tabs, so rows in the normal list are not all the same height. This
/// hit-tests the real row boxes instead, and the answer names a row rather than an index.
enum TabDropResolver {
    static func target(
        rows: [TabDragRow],
        point: CGPoint,
        axis: TabDragAxis,
        draggedID: UUID,
        draggedIsFolder: Bool
    ) -> TabDropTarget {
        // A folder only ever lines up against other folders; a tab can land anywhere.
        let candidates = rows.filter { $0.id != draggedID && (!draggedIsFolder || $0.isFolder) }
        guard let row = candidates.first(where: { $0.frame.contains(point) }) ?? nearest(candidates, to: point)
        else { return .emptySection }

        // A tab dropped on a folder row goes into the folder. Aura only reorders tabs
        // against tabs, so there is no "between a tab and a folder" to aim for.
        if row.isFolder, !draggedIsFolder { return .intoFolder(row.id) }

        let below = axis == .vertical ? point.y > row.frame.midY : point.x > row.frame.midX
        return .between(TabDropIndicator(targetID: row.id, below: below))
    }

    /// Off the end of the list, or in the gap between two rows: the closest row wins, so
    /// the line never disappears while the pointer is inside the section.
    private static func nearest(_ rows: [TabDragRow], to point: CGPoint) -> TabDragRow? {
        rows.min { squaredDistance($0.frame, point) < squaredDistance($1.frame, point) }
    }

    private static func squaredDistance(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }
}
