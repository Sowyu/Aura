import AppKit
import SwiftUI

enum TrackingEdge {
    case left
    case right
    case top
    case bottom
}

/// Hover reveal for compact-mode chrome. A thin band at the window edge brings the
/// chrome in as soon as the pointer touches it; while the chrome is up the whole row or
/// column stays hot, so the pointer can move through it without losing the reveal.
struct GlobalMouseTrackingArea: NSViewRepresentable {
    /// Width of the band that arms the reveal, measured from the window edge.
    static let hotZone: CGFloat = 12
    /// Grace period after the pointer leaves. Coming back inside cancels the hide.
    static let hideDelay: TimeInterval = 0.35
    /// Reach outside the window edge, so a fast flick past it still counts as inside.
    static let slack: CGFloat = 8

    @Binding var mouseEntered: Bool
    let edge: TrackingEdge
    /// How deep the revealed chrome is: the toolbar row height, the sidebar width.
    let revealedExtent: CGFloat
    /// Extra reasons to stay revealed with the pointer elsewhere: an open menu or
    /// launcher, a live URL edit, a downloads panel.
    var isHeld: () -> Bool = { false }

    /// The band the pointer has to be in, in screen coordinates. `hotZone` deep while the
    /// chrome is hidden, the full depth of the chrome once it is up, plus `slack` outside
    /// the window edge so a flick that overshoots still counts.
    static func hotRect(
        in frame: NSRect,
        edge: TrackingEdge,
        revealedExtent: CGFloat,
        revealed: Bool
    ) -> NSRect {
        let depth = revealed ? max(revealedExtent, hotZone) : hotZone
        switch edge {
        case .left:
            return NSRect(x: frame.minX - slack, y: frame.minY, width: depth + slack, height: frame.height)
        case .right:
            return NSRect(x: frame.maxX - depth, y: frame.minY, width: depth + slack, height: frame.height)
        case .top:
            return NSRect(x: frame.minX, y: frame.maxY - depth, width: frame.width, height: depth + slack)
        case .bottom:
            return NSRect(x: frame.minX, y: frame.minY - slack, width: frame.width, height: depth + slack)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = EdgeRevealView(edge: edge, revealedExtent: revealedExtent, isHeld: isHeld)
        view.onChange = { revealed in self.mouseEntered = revealed }
        view.revealed = mouseEntered
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? EdgeRevealView else { return }
        view.edge = edge
        view.revealedExtent = revealedExtent
        view.isHeld = isHeld
        view.onChange = { revealed in self.mouseEntered = revealed }
        // Something other than the pointer flipped the binding (downloads opening, a
        // shortcut); adopt it so the next pointer move does not fight it.
        view.revealed = mouseEntered
    }
}

/// Watches the pointer against one window edge. Owns no tracking of its own: the
/// per-window `WindowMouseMonitor` feeds it every mouse position.
private final class EdgeRevealView: NSView {
    var edge: TrackingEdge
    var revealedExtent: CGFloat
    var isHeld: () -> Bool
    var onChange: ((Bool) -> Void)?
    var revealed: Bool = false

    private let listenerID = UUID()
    private var hideWork: DispatchWorkItem?

    init(edge: TrackingEdge, revealedExtent: CGFloat, isHeld: @escaping () -> Bool) {
        self.edge = edge
        self.revealedExtent = revealedExtent
        self.isHeld = isHeld
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Never in the way of a click; this view only reads pointer positions.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            WindowMouseMonitor.removeListener(listenerID)
            return
        }
        WindowMouseMonitor.addListener(listenerID, in: window) { [weak self] location in
            self?.evaluate(location)
        }
    }

    deinit {
        hideWork?.cancel()
        // `viewDidMoveToWindow` only drops the listener when the view moves to a nil
        // window. A view released while still in one left its handler in the monitor,
        // which kept the monitor (and its catcher view) alive for the window's life.
        let id = listenerID
        MainActor.assumeIsolated { WindowMouseMonitor.removeListener(id) }
    }

    /// The window's own rect in screen coordinates, so the band sits at the window edge
    /// rather than at whatever frame SwiftUI gave this view.
    private var hotRect: NSRect {
        guard let window, let content = window.contentView else { return .zero }
        let frame = window.convertToScreen(content.convert(content.bounds, to: nil))
        return GlobalMouseTrackingArea.hotRect(
            in: frame,
            edge: edge,
            revealedExtent: revealedExtent,
            revealed: revealed
        )
    }

    /// A popover or extension panel opens its own key window over the chrome; the chrome
    /// under it has to stay up until it closes.
    private var isCoveredByPanel: Bool {
        guard NSApp.isActive, let window, let key = NSApp.keyWindow, key !== window else { return false }
        return key.parent === window
    }

    private func evaluate(_ location: NSPoint) {
        guard window != nil else { return }
        if hotRect.contains(location) {
            hideWork?.cancel()
            hideWork = nil
            guard !revealed else { return }
            revealed = true
            onChange?(true)
        } else if revealed, hideWork == nil {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, revealed else { return }
            hideWork = nil
            // Still held: check again a beat later instead of yanking the chrome away.
            if isHeld() || isCoveredByPanel {
                scheduleHide()
                return
            }
            revealed = false
            onChange?(false)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + GlobalMouseTrackingArea.hideDelay, execute: work)
    }
}

/// One mouse-moved source per window, shared by every edge tracker in it.
///
/// A local `.mouseMoved` monitor only sees events the window generates, and a window
/// generates them only for views that track mouse moves, so the pointer sitting on a
/// `WKWebView` can silence it. Two things fix that: `acceptsMouseMovedEvents`, which
/// makes the window post moves regardless of the view under the pointer, and a
/// full-window catcher view whose `.activeAlways` tracking area reports moves even when
/// the window is not key. The catcher declines hit-testing, so clicks pass through it.
@MainActor
enum WindowMouseMonitor {
    private static var monitors: [ObjectIdentifier: Monitor] = [:]
    private static var owners: [UUID: ObjectIdentifier] = [:]

    static func addListener(_ id: UUID, in window: NSWindow, handler: @escaping (NSPoint) -> Void) {
        removeListener(id)
        let key = ObjectIdentifier(window)
        let monitor = monitors[key] ?? Monitor(window: window)
        monitors[key] = monitor
        owners[id] = key
        monitor.listeners[id] = handler
    }

    static func removeListener(_ id: UUID) {
        guard let key = owners.removeValue(forKey: id), let monitor = monitors[key] else { return }
        monitor.listeners[id] = nil
        if monitor.listeners.isEmpty {
            monitor.stop()
            monitors[key] = nil
        }
    }

    @MainActor
    final class Monitor {
        var listeners: [UUID: (NSPoint) -> Void] = [:]
        private var localMonitor: Any?
        private let catcher = MouseCatcherView()

        init(window: NSWindow) {
            window.acceptsMouseMovedEvents = true
            catcher.onMoved = { [weak self] in self?.broadcast() }
            if let content = window.contentView {
                catcher.frame = content.bounds
                catcher.autoresizingMask = [.width, .height]
                content.addSubview(catcher)
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                MainActor.assumeIsolated { self?.broadcast() }
                return event
            }
        }

        func stop() {
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            localMonitor = nil
            catcher.removeFromSuperview()
            listeners.removeAll()
        }

        private func broadcast() {
            let location = NSEvent.mouseLocation
            for handler in listeners.values { handler(location) }
        }
    }
}

/// Full-window, invisible, and click-through: only there to keep mouse-moved events
/// coming while the pointer is over the web view.
private final class MouseCatcherView: NSView {
    var onMoved: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        onMoved?()
        super.mouseMoved(with: event)
    }

    /// The pointer leaving the window is the last report we get, and it is the one that
    /// starts the hide. Without it, chrome the pointer exited through would stay up.
    override func mouseExited(with event: NSEvent) {
        onMoved?()
        super.mouseExited(with: event)
    }
}
