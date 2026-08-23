import CoreGraphics
import Foundation
@testable import Aura
import Testing

@Suite("Launcher placement")
struct LauncherPlacementTests {
    private func origin(
        _ window: CGRect,
        width: CGFloat = LauncherPlacement.width,
        height: CGFloat = LauncherField.height
    ) -> CGPoint {
        LauncherPlacement.origin(in: window, panelWidth: width, panelHeight: height)
    }

    /// The whole panel centres on the window, so neither the sidebar's width nor the side
    /// it sits on may move it, and no window size tips it off the middle.
    @Test("Centres on the window, horizontally and vertically", arguments: [
        CGSize(width: 1200, height: 800),
        CGSize(width: 1920, height: 1080),
        CGSize(width: 700, height: 420)
    ])
    func centresOnWindow(size: CGSize) {
        let window = CGRect(origin: .zero, size: size)
        let width = LauncherPlacement.width(forWindowWidth: size.width)
        let origin = origin(window, width: width)

        #expect(origin.x + width / 2 == window.midX)
        #expect(origin.y + LauncherField.height / 2 == window.midY)
    }

    /// The launcher's overlay does not always start at the window's corner, so the rect it
    /// centres on carries a negative origin. The panel still lands on the window's middle.
    @Test("An offset overlay still centres on the window")
    func offsetOverlay() {
        let window = CGRect(x: -120, y: -38, width: 1200, height: 800)
        let origin = origin(window)

        #expect(origin.x + LauncherPlacement.width / 2 == window.midX)
        #expect(origin.y + LauncherField.height / 2 == window.midY)
    }

    /// Field plus suggestion list is one panel, and that panel keeps its middle on the
    /// window's middle as rows arrive, so the field rides upwards while the list grows.
    @Test("A grown panel re-centres, pushing the field up")
    func grownPanelRecentres() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 800)

        #expect(origin(window, height: 400).y == 200)
        #expect(origin(window, height: 600).y == 100)
    }

    /// A panel taller than the window would centre itself off the top; it stops 16 pt down
    /// instead and spills off the bottom, where the rows are the ones you scrolled past.
    @Test("A panel taller than the window clamps 16 pt from the top")
    func tallPanelClamps() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 800)
        #expect(origin(window, height: 1000).y == 16)
    }

    /// The clamp is measured from the window, not from zero, so an offset overlay keeps
    /// the same 16 pt gap.
    @Test("The clamp follows an offset window")
    func clampFollowsOffsetWindow() {
        let window = CGRect(x: -120, y: -38, width: 1200, height: 800)
        #expect(origin(window, height: 1000).y == -22)
    }

    /// A narrow window shrinks the panel, and the narrower panel keeps its gutters equal.
    @Test("A shrunk panel is centred too")
    func shrunkPanel() {
        let window = CGRect(x: 0, y: 0, width: 500, height: 400)
        let width = LauncherPlacement.width(forWindowWidth: window.width)

        #expect(width == 468)
        #expect(origin(window, width: width).x == 16)
    }

    /// Before the window is known the rect is empty, and the centred panel would sit above
    /// its top edge. The clamp is what keeps the point on screen.
    @Test("An empty window produces a finite point")
    func emptyWindow() {
        let origin = origin(.zero, width: 0)
        #expect(origin.x == 0)
        #expect(origin.y == 16)
    }

    /// 740 wide until the window cannot hold it, then a gutter either side, and never
    /// under 320 no matter how narrow the window gets.
    @Test("Width gives way only to a narrow window")
    func widthClamp() {
        #expect(LauncherPlacement.width(forWindowWidth: 1400) == 740)
        #expect(LauncherPlacement.width(forWindowWidth: 640) == 608)
        #expect(LauncherPlacement.width(forWindowWidth: 300) == 320)
    }
}
