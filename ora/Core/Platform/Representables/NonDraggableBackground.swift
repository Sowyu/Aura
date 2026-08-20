import AppKit
import SwiftUI

/// Stops a mouse drag from moving the window. Hidden-titlebar windows treat any view
/// that doesn't consume mouse-down as titlebar, so dragging to select text in the URL
/// field, or dragging across a button, would otherwise move the window.
struct NonDraggableBackground: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}
}

extension SwiftUI.View {
    /// Mouse drags on this view select or click; they never move the window.
    func windowDragDisabled() -> some SwiftUI.View {
        background(NonDraggableBackground())
    }
}
