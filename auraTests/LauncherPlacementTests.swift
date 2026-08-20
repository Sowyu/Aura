import CoreGraphics
import Foundation
@testable import Aura
import Testing

@Suite("Launcher placement")
struct LauncherPlacementTests {
    /// The launcher must land in the middle of the content pane, not the window, so the
    /// sidebar's width and side must not move it.
    @Test("Centres on the pane, not the window")
    func centresOnPane() {
        let sidebarOnLeft = CGRect(x: 260, y: 44, width: 940, height: 756)
        let sidebarOnRight = CGRect(x: 0, y: 44, width: 940, height: 756)

        #expect(LauncherPlacement.position(in: sidebarOnLeft).x == 730)
        #expect(LauncherPlacement.position(in: sidebarOnRight).x == 470)
    }

    /// 35% down the pane, measured from the pane's own top edge, so the 44 pt toolbar
    /// does not shift it.
    @Test("Sits 35% down the pane regardless of the toolbar")
    func verticalFraction() {
        let withToolbar = CGRect(x: 0, y: 44, width: 800, height: 400)
        let withoutToolbar = CGRect(x: 0, y: 0, width: 800, height: 400)

        #expect(LauncherPlacement.position(in: withToolbar).y == 184)
        #expect(LauncherPlacement.position(in: withoutToolbar).y == 140)
    }

    @Test("An empty pane produces a finite point")
    func emptyPane() {
        let position = LauncherPlacement.position(in: .zero)
        #expect(position.x == 0)
        #expect(position.y == 0)
    }
}
