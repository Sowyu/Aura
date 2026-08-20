import CoreGraphics
import Foundation
@testable import Aura
import Testing

@Suite("Launcher placement")
struct LauncherPlacementTests {
    /// The floating launcher centres on the window, so neither the sidebar's width nor
    /// the side it sits on may move it.
    @Test("Centres on the window")
    func centresOnWindow() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 800)

        #expect(LauncherPlacement.position(in: window).x == 600)
    }

    /// 35% down, measured from the window's own top edge.
    @Test("Sits mid-window, higher when raised")
    func verticalFraction() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 400)

        #expect(LauncherPlacement.position(in: window).y == 200)
        #expect(abs(LauncherPlacement.position(in: window, raised: true).y - 112) < 0.001)
    }

    @Test("An empty window produces a finite point")
    func emptyWindow() {
        let position = LauncherPlacement.position(in: .zero)
        #expect(position.x == 0)
        #expect(position.y == 0)
    }

    /// 640 wide until the window cannot hold it, then a gutter either side, and never
    /// under 320 no matter how narrow the window gets.
    @Test("Width gives way only to a narrow window")
    func widthClamp() {
        #expect(LauncherPlacement.width(forWindowWidth: 1400) == 640)
        #expect(LauncherPlacement.width(forWindowWidth: 640) == 608)
        #expect(LauncherPlacement.width(forWindowWidth: 300) == 320)
    }
}
