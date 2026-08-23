import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    @Binding var isFullscreen: Bool

    /// Mirrors `ToolbarManager.isToolbarHidden` so the native window buttons can
    /// move into the top toolbar row when it is visible.
    @AppStorage("ui.toolbar.hidden") private var isToolbarHidden: Bool = false

    /// Compact mode hides the row but hover-reveals it; the buttons ride along so the
    /// revealed row is identical to the pinned one.
    @Environment(ToolbarManager.self) private var toolbarManager

    /// Windows SwiftUI made itself never went through `WindowFactory`, so the glass
    /// setting is applied from here and reverted the moment it is switched off.
    @AppStorage(AuraGlass.enabledKey) private var glassEnabled = false

    /// Matches `TopToolbar`'s row height and leading inset.
    private static let toolbarHeight: CGFloat = TopToolbar.rowHeight
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

        /// Where the buttons belong right now. AppKit re-lays the titlebar out on
        /// window moves, activation and the end of a live resize, and every one of
        /// those puts the buttons back on its own 32pt midline. Setting the origin
        /// once is not enough, so every drift is corrected from `frameObservers`.
        var desiredOrigins: [NSWindow.ButtonType: NSPoint] = [:]
        var frameObservers: [Any] = []
        private var hasPendingPass = false

        /// Straight away, then once more on the next turn of the run loop. AppKit
        /// finishes moving the other two buttons after the first one's notification
        /// reaches us, so a purely synchronous pass leaves the last button behind.
        func applyDesiredOrigins(to buttons: [(NSWindow.ButtonType, NSButton)]) {
            setOrigins(on: buttons)
            guard !hasPendingPass else { return }
            hasPendingPass = true
            DispatchQueue.main.async { [weak self] in
                self?.hasPendingPass = false
                self?.setOrigins(on: buttons)
            }
        }

        private func setOrigins(on buttons: [(NSWindow.ButtonType, NSButton)]) {
            for (type, button) in buttons {
                guard let origin = desiredOrigins[type], button.frame.origin != origin else { continue }
                button.setFrameOrigin(origin)
            }
        }

        func observeFrames(of buttons: [(NSWindow.ButtonType, NSButton)]) {
            guard frameObservers.isEmpty else { return }
            frameObservers = buttons.map { _, button in
                button.postsFrameChangedNotifications = true
                return NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: button,
                    queue: nil
                ) { [weak self] _ in
                    self?.applyDesiredOrigins(to: buttons)
                }
            }
        }

        /// `invalidateShadow` on every SwiftUI update flickers the window edge, so the
        /// glass setting is only pushed at the window when it actually moved.
        var appliedGlass: Bool?

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
            window.disableImplicitDragging()

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
            applyGlass(to: window, coordinator: coordinator)
            updateTrafficLights(for: window, coordinator: coordinator)
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        applyGlass(to: window, coordinator: context.coordinator)
        updateTrafficLights(for: window, coordinator: context.coordinator)
    }

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        for observer in coordinator.observers + coordinator.frameObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        coordinator.frameObservers = []
    }

    private func applyGlass(to window: NSWindow, coordinator: Coordinator) {
        guard coordinator.appliedGlass != glassEnabled else { return }
        coordinator.appliedGlass = glassEnabled
        AuraGlass.applyWindowTransparency(to: window, enabled: glassEnabled)
    }

    private func updateTrafficLights(for window: NSWindow, coordinator: Coordinator) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { type in window.standardWindowButton(type).map { (type, $0) } }

        // The toolbar hosts the real window buttons; without it the sidebar/URL bar
        // draws its own controls and the native ones stay hidden.
        let rowIsUp = !isToolbarHidden || toolbarManager.isFloatingToolbarVisible
        let showInToolbar = rowIsUp && !isFullscreen

        for (_, button) in buttons {
            button.isHidden = !(isFullscreen || showInToolbar)
        }

        for (type, button) in buttons where coordinator.defaultOrigins[type] == nil {
            coordinator.defaultOrigins[type] = button.frame.origin
        }

        coordinator.observeFrames(of: buttons)

        guard showInToolbar else {
            coordinator.desiredOrigins = coordinator.defaultOrigins
            coordinator.applyDesiredOrigins(to: buttons)
            return
        }

        guard let containerHeight = buttons.first?.1.superview?.bounds.height else { return }
        // The titlebar view's top edge lines up with the top of the toolbar row, and
        // AppKit coordinates run upward from its bottom. Measured on macOS 26: the
        // view is 32pt and the buttons are 14pt, so AppKit's own placement centres
        // them 16pt from the top of the window while the row's midline is at 19pt.
        // The view is shorter than the row, so the origin can go negative; that is
        // correct, and NSView does not clip its subviews by default.
        let rowCenterY = containerHeight - Self.toolbarHeight / 2
        for (index, entry) in buttons.enumerated() {
            let size = entry.1.frame.size
            let originY = (rowCenterY - size.height / 2).rounded()
            let originX = Self.trafficLightLeading + CGFloat(index) * Self.trafficLightSpacing
            coordinator.desiredOrigins[entry.0] = NSPoint(x: originX, y: originY)
        }
        coordinator.applyDesiredOrigins(to: buttons)
    }
}
