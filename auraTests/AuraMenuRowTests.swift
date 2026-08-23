import AppKit
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

    /// A history menu can easily run past sixty rows. The panel caps itself to the window
    /// and scrolls the rest rather than running off the bottom edge.
    @Test("A 60 item menu is capped to the window with an 8pt margin")
    func aLongMenuIsCappedToTheWindow() {
        let items = (0..<60).map { AuraMenuItem.item("Row \($0)", action: {}) }
        let content = AuraMenuMetrics.height(of: items)
        let available: CGFloat = 800
        let fitted = AuraMenuMetrics.fittedHeight(contentHeight: content, available: available)

        #expect(content > available)
        #expect(fitted == available - AuraMenuMetrics.windowInset * 2)
        #expect(fitted <= available)
    }

    /// A menu that already fits is left alone, otherwise every short menu would grow to
    /// fill the window.
    @Test("A short menu keeps its natural height")
    func aShortMenuIsNotStretched() {
        let height = AuraMenuMetrics.height(of: menu)
        #expect(AuraMenuMetrics.fittedHeight(contentHeight: height, available: 800) == height)
        #expect(AuraMenuMetrics.fittedHeight(contentHeight: height, available: 4) == 0)
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

/// The one decision behind "the submenu will not go away": once the pointer leaves the
/// parent row, does it look like it is travelling into the open panel, or has it simply
/// moved to another row?
@MainActor
struct AuraMenuSafeZoneTests {
    /// Parent row's right edge at x 240, a 200x120 submenu opened to its right.
    private let exit = CGPoint(x: 236, y: 100)
    private let child = CGRect(x: 236, y: 96, width: 200, height: 120)

    @Test("A diagonal run at the panel keeps it open")
    func diagonalTravelIsAllowed() {
        #expect(AuraMenuSafeZone.allowsTravel(to: CGPoint(x: 300, y: 130), from: exit, toward: child, elapsed: 0.05))
        #expect(AuraMenuSafeZone.allowsTravel(to: CGPoint(x: 400, y: 180), from: exit, toward: child, elapsed: 0.2))
    }

    @Test("Dropping straight down the parent menu closes it")
    func movingDownTheListIsNotTravel() {
        #expect(!AuraMenuSafeZone.allowsTravel(to: CGPoint(x: 200, y: 130), from: exit, toward: child, elapsed: 0.01))
        #expect(!AuraMenuSafeZone.allowsTravel(to: CGPoint(x: 236, y: 160), from: exit, toward: child, elapsed: 0.01))
    }

    /// Aimed at the panel, but dawdling. Without the cap a pointer parked in the triangle
    /// sends no more events and pins the submenu open for good.
    @Test("The grace period expires even on a good heading")
    func graceExpires() {
        let heading = CGPoint(x: 300, y: 130)
        #expect(AuraMenuSafeZone.allowsTravel(to: heading, from: exit, toward: child, elapsed: 0.29))
        #expect(!AuraMenuSafeZone.allowsTravel(to: heading, from: exit, toward: child, elapsed: 0.31))
    }

    /// A submenu that hit the window edge opens to the left, and the triangle mirrors.
    @Test("A flipped submenu is aimed at leftwards")
    func flippedSubmenu() {
        let flipped = CGRect(x: 40, y: 96, width: 200, height: 120)
        let start = CGPoint(x: 244, y: 100)
        #expect(AuraMenuSafeZone.allowsTravel(to: CGPoint(x: 180, y: 130), from: start, toward: flipped, elapsed: 0.05))
        let away = CGPoint(x: 300, y: 130)
        #expect(!AuraMenuSafeZone.allowsTravel(to: away, from: start, toward: flipped, elapsed: 0.05))
    }
}

@MainActor
@Suite("Menu window side effects")
struct AuraMenuWindowTests {
    /// Mouse-moved delivery is switched on for the highlight and must be switched back,
    /// or every window that ever showed a menu keeps paying for those events.
    @Test("Dismiss restores the window's mouse-moved setting")
    func dismissRestoresMouseMoved() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = false
        let controller = AuraMenuController()
        controller.present([.item("One") {}], at: CGPoint(x: 10, y: 10), in: window)
        #expect(window.acceptsMouseMovedEvents)
        controller.dismiss()
        #expect(!window.acceptsMouseMovedEvents)
    }
}
