import AppKit
import SwiftUI

/// Right-click detection for SwiftUI rows.
///
/// SwiftUI has no gesture that hands back the AppKit event, and `.contextMenu` would bring
/// the native menu straight back, so the event is taken by a transparent AppKit overlay.
/// `hitTest` lets everything except right-clicks and ctrl-clicks fall through, which keeps
/// the row's own tap, drag and hover behaviour intact.
struct RightClickCatcher: NSViewRepresentable {
    /// Called with the click location in AppKit window coordinates, plus that window.
    let onRightClick: (CGPoint, NSWindow?) -> Void

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint, NSWindow?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(event.locationInWindow, window)
        }

        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control) else {
                super.mouseDown(with: event)
                return
            }
            onRightClick?(event.locationInWindow, window)
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

extension View {
    /// Replaces `.contextMenu`. The items are built at click time, so a menu always
    /// reflects current state without the view holding a copy of it.
    func auraContextMenu(_ items: @escaping () -> [AuraMenuItem]) -> some View {
        overlay(catcher(items))
    }

    /// Same, mounted behind the content instead of over it. `.contextMenu` let the
    /// innermost menu win; a catcher in the background gets only the right-clicks that no
    /// nested row claimed, which restores that for container views like the sidebar.
    func auraBackgroundContextMenu(_ items: @escaping () -> [AuraMenuItem]) -> some View {
        background(catcher(items))
    }

    private func catcher(_ items: @escaping () -> [AuraMenuItem]) -> some View {
        RightClickCatcher { point, window in
            AuraMenuController.shared.present(items(), at: point, in: window)
        }
    }
}

/// Anchors a menu under a toolbar button. Zero-sized and flipped so callers can talk
/// about the button's own bounds without worrying which way the host view points.
struct AuraMenuAnchorView: NSViewRepresentable {
    let onViewCreated: (NSView) -> Void

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        DispatchQueue.main.async { onViewCreated(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension NSView {
    /// Presents `items` under this view, the way a toolbar button's menu should hang.
    @MainActor
    func presentAuraMenu(_ items: [AuraMenuItem]) {
        let rect = convert(bounds, to: nil)
        AuraMenuController.shared.present(items, at: rect.origin, anchor: .below(rect), in: window)
    }
}
