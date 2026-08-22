import Foundation
@testable import Aura
import Testing

/// Where the sidebar's insertion line lands for a given pointer position. This is the
/// whole of the drag's position logic, so it is worth pinning down without a window.
struct TabDropResolverTests {
    private let dragged = UUID()

    private func row(_ id: UUID, x: CGFloat = 0, y: CGFloat, isFolder: Bool = false) -> TabDragRow {
        TabDragRow(id: id, isFolder: isFolder, frame: CGRect(x: x, y: y, width: 200, height: 40))
    }

    private func resolve(
        _ rows: [TabDragRow],
        _ point: CGPoint,
        axis: TabDragAxis = .vertical,
        isFolder: Bool = false
    ) -> TabDropTarget {
        TabDropResolver.target(
            rows: rows,
            point: point,
            axis: axis,
            draggedID: dragged,
            draggedIsFolder: isFolder
        )
    }

    @Test func upperHalfOfARowPutsTheLineAbove() {
        let target = UUID()
        let result = resolve([row(dragged, y: 0), row(target, y: 40)], CGPoint(x: 100, y: 50))
        #expect(result == .between(TabDropIndicator(targetID: target, below: false)))
    }

    @Test func lowerHalfOfARowPutsTheLineBelow() {
        let target = UUID()
        let result = resolve([row(dragged, y: 0), row(target, y: 40)], CGPoint(x: 100, y: 75))
        #expect(result == .between(TabDropIndicator(targetID: target, below: true)))
    }

    @Test func pastTheLastRowFallsBackToTheNearestOne() {
        let last = UUID()
        let result = resolve([row(dragged, y: 0), row(last, y: 40)], CGPoint(x: 100, y: 400))
        #expect(result == .between(TabDropIndicator(targetID: last, below: true)))
    }

    @Test func aTabOverAFolderRowGoesInside() {
        let folder = UUID()
        let result = resolve([row(dragged, y: 0), row(folder, y: 40, isFolder: true)], CGPoint(x: 100, y: 50))
        #expect(result == .intoFolder(folder))
    }

    @Test func aFolderOverAFolderRowReordersInsteadOfNesting() {
        let folder = UUID()
        let result = resolve(
            [row(dragged, y: 0, isFolder: true), row(folder, y: 40, isFolder: true)],
            CGPoint(x: 100, y: 75),
            isFolder: true
        )
        #expect(result == .between(TabDropIndicator(targetID: folder, below: true)))
    }

    @Test func aDraggedFolderIgnoresTabRows() {
        let folder = UUID()
        let rows = [row(dragged, y: 0, isFolder: true), row(UUID(), y: 40), row(folder, y: 200, isFolder: true)]
        // The pointer sits on the tab row, but only folders are candidates.
        let result = resolve(rows, CGPoint(x: 100, y: 50), isFolder: true)
        #expect(result == .between(TabDropIndicator(targetID: folder, below: false)))
    }

    @Test func aSectionHoldingOnlyTheDraggedRowIsEmpty() {
        #expect(resolve([row(dragged, y: 0)], CGPoint(x: 100, y: 10)) == .emptySection)
        #expect(resolve([], CGPoint(x: 100, y: 10)) == .emptySection)
    }

    @Test func theFavouritesGridSplitsOnXInsteadOfY() {
        let target = UUID()
        let rows = [row(dragged, x: 0, y: 0), row(target, x: 200, y: 0)]
        #expect(resolve(rows, CGPoint(x: 250, y: 20), axis: .horizontal)
            == .between(TabDropIndicator(targetID: target, below: false)))
        #expect(resolve(rows, CGPoint(x: 350, y: 20), axis: .horizontal)
            == .between(TabDropIndicator(targetID: target, below: true)))
    }
}
