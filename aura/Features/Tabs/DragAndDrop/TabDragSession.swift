//
//  TabDragSession.swift
//  Aura
//
//  Ported from Nook (github.com/nook-browser/nook, GPL-3.0), files
//  Nook/Components/DragDrop/NookDragSessionManager.swift and NookDragItem.swift.
//  Copyright (c) Nook contributors. Adapted for Aura's order-based model: Nook tracks an
//  insertion *index* per zone, Aura tracks the row the line is drawn against.
//

import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    /// Private to Aura, so a sidebar row cannot be dropped into another app as a bare UUID.
    static let auraTabItem = NSPasteboard.PasteboardType("com.aurabrowser.app.tab-drag-item")
}

/// One drop zone per sidebar section, per space. Spaces stay mounted behind the visible
/// one, so the space id has to be part of the identity or two spaces share a zone.
enum TabDragZone: Hashable {
    case fav(UUID)
    case pinned(UUID)
    case normal(UUID)

    var containerID: UUID {
        switch self {
        case let .fav(id), let .pinned(id), let .normal(id): return id
        }
    }

    var section: TabSection {
        switch self {
        case .fav: return .fav
        case .pinned: return .pinned
        case .normal: return .normal
        }
    }

    /// The favourites grid flows left to right; the other two run down the sidebar.
    var axis: TabDragAxis {
        if case .fav = self { return .horizontal }
        return .vertical
    }
}

enum TabDragAxis {
    case vertical
    case horizontal
}

/// A row's hit box, in its zone's flipped (top-left origin) coordinates.
struct TabDragRow: Equatable {
    let id: UUID
    let isFolder: Bool
    let frame: CGRect
}

/// Where a dragged row will land: on the top or bottom edge of `targetID`'s row.
struct TabDropIndicator: Equatable {
    let targetID: UUID
    let below: Bool
}

enum TabDropTarget: Equatable {
    case between(TabDropIndicator)
    /// Onto a folder row, which means "put it inside".
    case intoFolder(UUID)
    /// Nothing in the zone to line up against, so the drop only changes section.
    case emptySection
}

/// Handed to the space that owns the zone once the pointer comes up.
struct PendingTabDrop: Equatable {
    let draggedID: UUID
    let zone: TabDragZone
    let target: TabDropTarget
}

/// Every sidebar drag runs through here. Nothing moves while the pointer is down: the
/// session only records what is being dragged and where the line sits, and the drop is
/// committed once, on release, by the space that owns the target zone.
@MainActor
final class TabDragSession: ObservableObject {
    static let shared = TabDragSession()

    @Published private(set) var draggedID: UUID?
    @Published private(set) var activeZone: TabDragZone?
    @Published private(set) var target: TabDropTarget?
    /// Set on release, consumed by the owning space, then cleared. It outlives the rest
    /// of the drag state by a turn, which is why it is not reset in `end()`.
    @Published var pendingDrop: PendingTabDrop?

    /// Set from the rows' hover. The sidebar's window drag gesture reads it: a press
    /// that lands on a row starts that row's drag, and the window must stay put.
    @Published private(set) var pointerOnRow = false

    private(set) var draggedIsFolder = false
    private(set) var sourceZone: TabDragZone?
    private var hoveredRowID: UUID?

    var isDragging: Bool { draggedID != nil }

    // MARK: - Presentation

    /// The insertion line for one row, or nil when the line belongs elsewhere.
    func indicator(for id: UUID, in zone: TabDragZone) -> TabDropIndicator? {
        guard activeZone == zone, case let .between(indicator) = target, indicator.targetID == id
        else { return nil }
        return indicator
    }

    func isFolderTarget(_ id: UUID) -> Bool {
        if case let .intoFolder(folderID) = target { return folderID == id }
        return false
    }

    /// Moving from one row to the next can report the new row first, so a row only
    /// clears the flag when it is still the one holding it.
    func setPointerOnRow(_ id: UUID, _ hovering: Bool) {
        if hovering {
            hoveredRowID = id
        } else if hoveredRowID == id {
            hoveredRowID = nil
        }
        let next = hoveredRowID != nil
        if next != pointerOnRow { pointerOnRow = next }
    }

    // MARK: - Lifecycle

    func begin(id: UUID, isFolder: Bool, in zone: TabDragZone) {
        draggedID = id
        draggedIsFolder = isFolder
        sourceZone = zone
        activeZone = zone
        target = nil
    }

    func entered(_ zone: TabDragZone) {
        guard isDragging, activeZone != zone else { return }
        activeZone = zone
        target = nil
        performHapticFeedback(pattern: .alignment)
    }

    func exited(_ zone: TabDragZone) {
        guard activeZone == zone else { return }
        activeZone = nil
        target = nil
    }

    func update(_ zone: TabDragZone, at point: CGPoint, rows: [TabDragRow]) {
        guard let draggedID else { return }
        if activeZone != zone { activeZone = zone }
        let next = TabDropResolver.target(
            rows: rows,
            point: point,
            axis: zone.axis,
            draggedID: draggedID,
            draggedIsFolder: draggedIsFolder
        )
        guard next != target else { return }
        target = next
        performHapticFeedback(pattern: .alignment)
    }

    func drop(in zone: TabDragZone) -> Bool {
        guard let draggedID, let target else { return false }
        pendingDrop = PendingTabDrop(draggedID: draggedID, zone: zone, target: target)
        performHapticFeedback(pattern: .generic)
        return true
    }

    /// An AppKit dragging session always reports its end, on drop and on Esc alike, so
    /// this is the only place the transient state is cleared. The old code had to guess
    /// the end from a mouse-up monitor, because SwiftUI's `.onDrag` reports nothing.
    func end() {
        draggedID = nil
        draggedIsFolder = false
        sourceZone = nil
        activeZone = nil
        target = nil
    }
}
