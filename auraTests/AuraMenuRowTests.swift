import CoreGraphics
@testable import Aura
import Testing

/// Menu rows are placed and hit-tested from the same table of heights, never measured.
/// If the two ever disagree, a click lands on the row above or below the one under the
/// pointer, which is the kind of bug nobody reports precisely.
@MainActor
struct AuraMenuRowTests {
    private var menu: [AuraMenuItem] {
        [
            .header("Recent"),
            .item("Back", action: {}),
            .separator,
            .item("Reload", action: {}),
            .submenu("JavaScript", items: [.item("Allow", action: {})]),
            .disabled("No recent history")
        ]
    }

    @Test("Every row is found at the offset it was placed at")
    func offsetsAndHitsAgree() {
        let items = menu
        for index in items.indices {
            let top = AuraMenuMetrics.offset(ofRow: index, in: items)
            let bottom = top + AuraMenuMetrics.height(of: items[index])

            #expect(AuraMenuMetrics.row(atOffset: top, in: items) == index)
            #expect(AuraMenuMetrics.row(atOffset: (top + bottom) / 2, in: items) == index)
            #expect(AuraMenuMetrics.row(atOffset: bottom - 0.01, in: items) == index)
        }
    }

    /// A 28pt row is the whole target: its last pixel must not belong to the next row.
    @Test("A row owns its full 28pt band")
    func rowsOwnTheirBand() {
        let items = menu
        let index = 3
        let top = AuraMenuMetrics.offset(ofRow: index, in: items)

        #expect(AuraMenuMetrics.height(of: items[index]) == AuraMenuMetrics.rowHeight)
        #expect(AuraMenuMetrics.row(atOffset: top - 0.01, in: items) == index - 1)
        #expect(AuraMenuMetrics.row(atOffset: top + AuraMenuMetrics.rowHeight, in: items) == index + 1)
    }

    @Test("The padding above and below the list belongs to no row")
    func paddingIsNotARow() {
        let items = menu
        let height = AuraMenuMetrics.height(of: items)

        #expect(AuraMenuMetrics.row(atOffset: 0, in: items) == nil)
        #expect(AuraMenuMetrics.row(atOffset: height - 1, in: items) == nil)
        #expect(AuraMenuMetrics.row(atOffset: height + 40, in: items) == nil)
    }

    @Test("The panel is exactly as tall as the rows it holds")
    func heightIsTheSumOfTheRows() {
        let items = menu
        let rows = items.reduce(CGFloat.zero) { $0 + AuraMenuMetrics.height(of: $1) }

        #expect(AuraMenuMetrics.height(of: items) == rows + AuraMenuMetrics.verticalPadding * 2)
    }

    /// Optional sections compile out to nothing, so separators are tidied rather than
    /// guarded at every call site.
    @Test("Leading, trailing and doubled separators are dropped")
    func separatorsAreTidied() {
        let tidied: [AuraMenuItem] = [
            .separator,
            .item("Back", action: {}),
            .separator,
            .separator,
            .item("Reload", action: {}),
            .separator
        ].tidied()

        #expect(tidied.map(\.kind) == [.item, .separator, .item])
    }

    @Test("A separator after a header is dropped, one before it is kept")
    func separatorsAroundHeaders() {
        let tidied: [AuraMenuItem] = [
            .item("Back", action: {}),
            .separator,
            .header("Recent"),
            .separator,
            .item("Reload", action: {})
        ].tidied()

        #expect(tidied.map(\.kind) == [.item, .separator, .header, .item])
    }

    /// Rows the pointer and the arrow keys must skip.
    @Test("Headers, separators and disabled rows are not selectable")
    func selectableRows() {
        #expect(menu.map(\.isSelectable) == [false, true, false, true, true, false])
    }
}
