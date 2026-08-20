import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    @Binding var isFullscreen: Bool

    /// Mirrors `ToolbarManager.isToolbarHidden` so the native window buttons can
    /// move into the top toolbar row when it is visible.
    @AppStorage("ui.toolbar.hidden") private var isToolbarHidden: Bool = false

    /// Matches `TopToolbar`'s row height and leading inset.
    private static let toolbarHeight: CGFloat = 44
    private static let trafficLightLeading: CGFloat = 12
    private static let trafficLightSpacing: CGFloat = 20

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator {
        var parent: WindowAccessor
        var observers: [Any] = []

        init(_ parent: WindowAccessor) {
            self.parent = parent
        }

        /// Origins AppKit gave the window buttons before we moved them.
        var defaultOrigins: [NSWindow.ButtonType: NSPoint] = [:]

        @objc func willEnterFullScreenNotification(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            parent.isFullscreen = true
            parent.updateTrafficLights(for: window, coordinator: self)
        }

        @objc func willExitFullScreenNotification(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            parent.isFullscreen = false
            parent.updateTrafficLights(for: window, coordinator: self)
        }

        @objc func windowDidResize(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            // AppKit re-lays out the buttons on resize, so re-apply our origins.
            parent.updateTrafficLights(for: window, coordinator: self)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            guard let window = view.window else { return }
            isFullscreen = window.styleMask.contains(.fullScreen)

            let coordinator = context.coordinator

            let enterObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: nil,
                using: coordinator.willEnterFullScreenNotification
            )

            let exitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: window,
                queue: nil,
                using: coordinator.willExitFullScreenNotification
            )

            let resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: nil,
                using: coordinator.windowDidResize
            )

            coordinator.observers = [enterObserver, exitObserver, resizeObserver]
            updateTrafficLights(for: window, coordinator: coordinator)
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        updateTrafficLights(for: window, coordinator: context.coordinator)
    }

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        for observer in coordinator.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateTrafficLights(for window: NSWindow, coordinator: Coordinator) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { type in window.standardWindowButton(type).map { (type, $0) } }

        // The toolbar hosts the real window buttons; without it the sidebar/URL bar
        // draws its own controls and the native ones stay hidden.
        let showInToolbar = !isToolbarHidden && !isFullscreen

        for (_, button) in buttons {
            button.animator().isHidden = !(isFullscreen || showInToolbar)
        }

        for (type, button) in buttons where coordinator.defaultOrigins[type] == nil {
            coordinator.defaultOrigins[type] = button.frame.origin
        }

        guard showInToolbar else {
            for (type, button) in buttons {
                if let origin = coordinator.defaultOrigins[type] {
                    button.setFrameOrigin(origin)
                }
            }
            return
        }

        guard let containerHeight = buttons.first?.1.superview?.bounds.height else { return }
        // The titlebar container's top edge lines up with the top of the toolbar
        // row, and AppKit coordinates run upward from its bottom. The container is
        // usually shorter than 44pt, so the origin goes negative; that is correct,
        // and NSView does not clip its subviews by default.
        let rowCenterY = containerHeight - Self.toolbarHeight / 2
        for (index, entry) in buttons.enumerated() {
            let size = entry.1.frame.size
            let originY = (rowCenterY - size.height / 2).rounded()
            let originX = Self.trafficLightLeading + CGFloat(index) * Self.trafficLightSpacing
            entry.1.setFrameOrigin(NSPoint(x: originX, y: originY))
        }
    }
}
