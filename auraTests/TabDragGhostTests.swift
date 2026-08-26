import AppKit
import SwiftUI
import XCTest
@testable import Aura

/// The drag ghost is rendered off the host layer. A blank image here means the drag has
/// no visible row under the pointer again.
@MainActor
final class TabDragGhostTests: XCTestCase {
    private let zone = TabDragZone.normal(UUID())
    private let rowID = UUID()

    func testGhostShowsTheDraggedRowRightWayUp() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = VStack(spacing: 0) {
            Color.red.frame(height: 40)
            Color.blue.frame(height: 40).tabDragSource(id: rowID, in: zone)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = window.contentView!.bounds
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        let source = try XCTUnwrap(TabDragSourceRegistry.shared.views(in: zone, window: window).first)
        let image = source.snapshot()
        XCTAssertEqual(image.size, NSSize(width: 200, height: 40))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let centre = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
            .usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(centre.blueComponent, 0.8, "ghost should show the dragged (blue) row")
        XCTAssertLessThan(centre.redComponent, 0.2, "ghost picked up the row above instead")
    }
}

/// A press in another window (an extension popup over the sidebar, a popover, a
/// sheet) must never start a row drag in the browser window beneath it.
@MainActor
final class TabDragPressWindowTests: XCTestCase {
    func testAPressInAnotherWindowPressesNoRow() throws {
        let rowWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        rowWindow.isReleasedWhenClosed = false
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        other.isReleasedWhenClosed = false
        defer { rowWindow.close()
            other.close()
        }
        let zone = TabDragZone.normal(UUID())
        let row = TabDragSourceNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        row.rowID = UUID()
        row.zone = zone
        rowWindow.contentView?.addSubview(row)
        row.register()
        defer { row.unregister() }
        rowWindow.orderFront(nil)
        let point = NSPoint(x: 20, y: 20)
        func press(in window: NSWindow) -> TabDragSourceNSView? {
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
            return TabDragSourceRegistry.shared.pressedSource(for: event)
        }
        XCTAssertTrue(press(in: rowWindow) === row, "a press in the row's own window finds it")
        XCTAssertNil(press(in: other), "a press in another window over the same screen spot must not")
    }
}
