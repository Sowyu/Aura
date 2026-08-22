//
//  TabDragSourceView.swift
//  Aura
//
//  Ported from Nook's NookDragSourceView.swift and the event monitor in
//  NookDragSessionManager.swift (github.com/nook-browser/nook, GPL-3.0).
//  Copyright (c) Nook contributors. Adapted: the drag image is a snapshot of the row
//  rather than Nook's floating preview window, and rows report their own hit boxes.
//

import AppKit
import SwiftUI

// MARK: - Registry

/// SwiftUI keeps mouse events to itself, so a row's backing view never sees a mouseDown.
/// One local monitor watches them for every row instead and starts an AppKit dragging
/// session on whichever row the press began in, once the pointer has moved far enough to
/// mean a drag rather than a click.
@MainActor
final class TabDragSourceRegistry {
    static let shared = TabDragSourceRegistry()
    private static let threshold: CGFloat = 4

    private struct WeakSource {
        weak var view: TabDragSourceNSView?
    }

    private var sources: [UUID: WeakSource] = [:]
    private var monitor: Any?
    private weak var pressedView: TabDragSourceNSView?
    private var pressedPoint: NSPoint?
    private var didStart = false

    func register(_ view: TabDragSourceNSView, id: UUID) {
        sources[id] = WeakSource(view: view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func unregister(id: UUID) {
        sources.removeValue(forKey: id)
        sources = sources.filter { $0.value.view != nil }
        guard sources.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// The live rows of one zone. Their boxes are read off the views while the pointer
    /// moves, so nothing has to be kept in sync as the sidebar scrolls, opens a folder,
    /// or recycles a row out of the lazy stack.
    func views(in zone: TabDragZone, window: NSWindow?) -> [TabDragSourceNSView] {
        sources.values.compactMap(\.view).filter { $0.zone == zone && $0.window === window }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if TabDragSession.shared.isDragging { return event }
        switch event.type {
        case .leftMouseDown:
            reset()
            pressedView = pressedSource(for: event)
            pressedPoint = event.locationInWindow
            // Always passed through: a click still has to select the tab.
            return event
        case .leftMouseDragged:
            guard let source = pressedView, let pressedPoint, !didStart else { return event }
            let moved = hypot(
                event.locationInWindow.x - pressedPoint.x,
                event.locationInWindow.y - pressedPoint.y
            )
            guard moved >= Self.threshold else { return event }
            didStart = true
            source.initiateDrag(with: event)
            return nil
        case .leftMouseUp:
            reset()
            return event
        default:
            return event
        }
    }

    /// Smallest box wins, so a row nested inside another one is not shadowed by its parent.
    /// The point is routed through the screen rather than `event.window`, which a local
    /// monitor does not always have filled in yet.
    private func pressedSource(for event: NSEvent) -> TabDragSourceNSView? {
        let screenPoint = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
            ?? event.locationInWindow
        return sources.values
            .compactMap(\.view)
            .filter { view in
                guard let window = view.window, window.isKeyWindow else { return false }
                let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
                return view.bounds.contains(point)
            }
            .min { $0.bounds.height * $0.bounds.width < $1.bounds.height * $1.bounds.width }
    }

    private func reset() {
        pressedView = nil
        pressedPoint = nil
        didStart = false
    }
}

// MARK: - Source view

final class TabDragSourceNSView: NSView {
    var rowID: UUID = UUID()
    var isFolder = false
    var zone: TabDragZone = .normal(UUID())

    private var registeredID: UUID?

    /// Top-left origin throughout, so row boxes and pointer positions agree with SwiftUI.
    override var isFlipped: Bool { true }

    /// The view only exists to be measured and dragged from; clicks belong to SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func register() {
        let id = UUID()
        registeredID = id
        TabDragSourceRegistry.shared.register(self, id: id)
    }

    func unregister() {
        guard let registeredID else { return }
        TabDragSourceRegistry.shared.unregister(id: registeredID)
        self.registeredID = nil
    }

    func initiateDrag(with event: NSEvent) {
        // Snapshot before the session starts, or the ghost picks up the dimming that the
        // row takes on while it is being dragged.
        let contents = snapshot()
        TabDragSession.shared.begin(id: rowID, isFolder: isFolder, in: zone)

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(rowID.uuidString, forType: .auraTabItem)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(bounds, contents: contents)
        beginDraggingSession(with: [item], event: event, source: TabDragSourceCoordinator.shared)
    }

    private func snapshot() -> NSImage {
        let blank = NSImage(size: NSSize(width: 1, height: 1))
        guard let host = superview, bounds.width > 1, bounds.height > 1 else { return blank }
        let rect = convert(bounds, to: host)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return blank }
        host.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Dragging source

/// Stateless, so one instance serves every row.
@MainActor
final class TabDragSourceCoordinator: NSObject, NSDraggingSource {
    static let shared = TabDragSourceCoordinator()

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // A sidebar row means nothing outside Aura, so a drop there is a cancel.
        context == .withinApplication ? .move : []
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        DispatchQueue.main.async { TabDragSession.shared.end() }
    }
}

// MARK: - SwiftUI

private struct TabDragSourceAnchor: NSViewRepresentable {
    let id: UUID
    let isFolder: Bool
    let zone: TabDragZone

    func makeNSView(context: Context) -> TabDragSourceNSView {
        let view = TabDragSourceNSView()
        view.rowID = id
        view.isFolder = isFolder
        view.zone = zone
        view.register()
        return view
    }

    func updateNSView(_ nsView: TabDragSourceNSView, context: Context) {
        nsView.rowID = id
        nsView.isFolder = isFolder
        nsView.zone = zone
    }

    static func dismantleNSView(_ nsView: TabDragSourceNSView, coordinator: ()) {
        nsView.unregister()
    }
}

extension View {
    /// Makes the row draggable and lets the section measure it. The hover report is what
    /// keeps the window from being dragged along with the tab: the pointer is over the
    /// row well before the press, so the sidebar's window drag gesture is already off.
    func tabDragSource(id: UUID, isFolder: Bool = false, in zone: TabDragZone) -> some View {
        background(TabDragSourceAnchor(id: id, isFolder: isFolder, zone: zone))
            .onHover { TabDragSession.shared.setPointerOnRow(id, $0) }
    }
}
