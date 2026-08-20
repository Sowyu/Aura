import AppKit
import SwiftUI

/// An AppKit view that owns the mouse-down for the SwiftUI content under it.
///
/// Hidden-titlebar windows treat any view that doesn't consume mouse-down as titlebar,
/// so a drag on SwiftUI-drawn text moves the window. SwiftUI gestures fire on mouse-up,
/// too late. This overlay takes the event on mouse-down, refuses to move the window,
/// and runs `onMouseDown` (e.g. enter URL editing) so a drag lands in a real text field.
struct MouseDownCatcher: NSViewRepresentable {
    var onMouseDown: () -> Void

    final class View: NSView {
        var onMouseDown: () -> Void = {}
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { onMouseDown() }
        override func mouseDragged(with event: NSEvent) {}
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ nsView: View, context: Context) { nsView.onMouseDown = onMouseDown }
}
