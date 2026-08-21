import AppKit
import SwiftUI

/// Right-click detection for SwiftUI rows.
///
/// SwiftUI has no gesture that hands back the AppKit event, and `.contextMenu` would bring
/// the native menu straight back, so the event is taken by a transparent AppKit overlay.
/// The overlay never hit-tests; a single event monitor routes right-clicks to it.
struct RightClickCatcher: NSViewRepresentable {
    /// Called with the click location in AppKit window coordinates, plus that window.
    let onRightClick: (CGPoint, NSWindow?) -> Void

    /// Never hit-tests, so it cannot interfere with clicks, drags, hover or synthetic input
    /// (remote-control tools). Right-clicks arrive via one app-wide event monitor that picks
    /// the smallest registered catcher under the pointer, so nested rows beat containers.
    final class CatcherView: NSView {
        var onRightClick: ((CGPoint, NSWindow?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { Registry.shared.remove(self) } else { Registry.shared.add(self) }
        }

        func contains(windowPoint: CGPoint) -> Bool {
            guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
            return bounds.contains(convert(windowPoint, from: nil))
        }
    }

    @MainActor
    final class Registry {
        static let shared = Registry()
        private var views = NSHashTable<CatcherView>.weakObjects()
        private var monitor: Any?

        func add(_ view: CatcherView) {
            views.add(view)
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
                MainActor.assumeIsolated { Registry.shared.handle(event) }
            }
        }

        func remove(_ view: CatcherView) { views.remove(view) }

        private func handle(_ event: NSEvent) -> NSEvent? {
            let isContextClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard isContextClick, let window = event.window else { return event }
            let point = event.locationInWindow
            let candidates = views.allObjects.filter { $0.window === window && $0.contains(windowPoint: point) }
            let area = { (view: CatcherView) in view.bounds.width * view.bounds.height }
            guard let target = candidates.min(by: { area($0) < area($1) }) else { return event }
            target.onRightClick?(point, window)
            return nil
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
