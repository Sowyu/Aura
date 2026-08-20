import AppKit
import Testing

@testable import Aura

/// The hover-reveal band: 12pt at the window edge while the chrome is hidden, the full
/// depth of the chrome once it is out.
@MainActor
struct ChromeRevealZoneTests {
    private let window = NSRect(x: 100, y: 200, width: 1000, height: 800)

    @Test func hiddenBandIsTwelvePointsAtTheEdge() {
        let left = GlobalMouseTrackingArea.hotRect(in: window, edge: .left, revealedExtent: 300, revealed: false)
        #expect(left.contains(NSPoint(x: 105, y: 500)))
        #expect(!left.contains(NSPoint(x: 150, y: 500)))

        let top = GlobalMouseTrackingArea.hotRect(in: window, edge: .top, revealedExtent: 44, revealed: false)
        #expect(top.contains(NSPoint(x: 600, y: window.maxY - 5)))
        #expect(!top.contains(NSPoint(x: 600, y: window.maxY - 30)))
    }

    @Test func revealedBandCoversTheWholeChrome() {
        let left = GlobalMouseTrackingArea.hotRect(in: window, edge: .left, revealedExtent: 300, revealed: true)
        #expect(left.contains(NSPoint(x: 350, y: 500)))
        #expect(!left.contains(NSPoint(x: 450, y: 500)))

        let top = GlobalMouseTrackingArea.hotRect(in: window, edge: .top, revealedExtent: 44, revealed: true)
        #expect(top.contains(NSPoint(x: 600, y: window.maxY - 40)))
        #expect(!top.contains(NSPoint(x: 600, y: window.maxY - 60)))
    }

    @Test func bandReachesOutsideTheWindowEdge() {
        let right = GlobalMouseTrackingArea.hotRect(in: window, edge: .right, revealedExtent: 300, revealed: false)
        #expect(right.contains(NSPoint(x: window.maxX + 4, y: 500)))

        let top = GlobalMouseTrackingArea.hotRect(in: window, edge: .top, revealedExtent: 44, revealed: false)
        #expect(top.contains(NSPoint(x: 600, y: window.maxY + 4)))
    }

    /// A chrome shallower than the band never shrinks it.
    @Test func revealedBandNeverShrinksBelowTheHotZone() {
        let top = GlobalMouseTrackingArea.hotRect(in: window, edge: .top, revealedExtent: 2, revealed: true)
        #expect(top.contains(NSPoint(x: 600, y: window.maxY - 10)))
    }
}
