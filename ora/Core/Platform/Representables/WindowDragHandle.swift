import AppKit
import SwiftUI

/// Explicit window-drag region. Browser windows set `isMovable = false` so AppKit's
/// titlebar never steals a drag that started on the URL field or a button; moving
/// the window is done here, from empty chrome, via `performDrag`.
struct WindowDragHandle: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}
}

extension NSWindow {
    /// Chrome decides what drags; see `WindowDragHandle`.
    func disableImplicitDragging() {
        isMovable = false
        isMovableByWindowBackground = false
    }
}
