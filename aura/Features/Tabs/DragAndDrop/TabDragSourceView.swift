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
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .otherMouseUp]
        ) { [weak self] event in
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
        case .otherMouseUp:
            // SwiftUI's gestures never see the middle button, so the close lives here.
            // Any other button, or a click outside every row, is left alone.
            guard event.buttonNumber == 2, let source = pressedSource(for: event),
                  let close = source.onMiddleClick
            else { return event }
            close()
            return nil
        default:
            return event
        }
    }

    /// Smallest box wins, so a row nested inside another one is not shadowed by its parent.
    /// Only rows in the event's own window qualify: a press inside an extension popup or a
    /// popover floating over the sidebar used to press the row underneath, and then
    /// swallow the drag that followed.
    func pressedSource(for event: NSEvent) -> TabDragSourceNSView? {
        guard let eventWindow = event.window else { return nil }
        return sources.values
            .compactMap(\.view)
            .filter { view in
                guard let window = view.window, window === eventWindow else { return false }
                return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
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
    /// Nil for a row that has nothing to close, such as a folder header.
    var onMiddleClick: (() -> Void)?
    /// What the row means outside Aura. Nil for a folder, which is not an address.
    var dragURL: URL?
    var dragTitle = ""

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

        let item = NSDraggingItem(pasteboardWriter: pasteboardWriter())
        // Slightly smaller than the row, centred on it, so it reads as lifted off the list.
        let ghost = bounds.insetBy(dx: bounds.width * 0.03, dy: bounds.height * 0.03)
        item.setDraggingFrame(ghost, contents: contents)
        let session = beginDraggingSession(with: [item], event: event, source: TabDragSourceCoordinator.shared)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    /// A tab carries its address out of the app as well as its row identity, so dragging
    /// it to Finder writes a link file and dragging it into another browser opens the
    /// page. A folder has no address and keeps the bare item it always had, which is also
    /// what every intra-app drop reads.
    /// Internal rather than private so the tests can check both branches without a drag.
    func pasteboardWriter() -> NSPasteboardWriting {
        // An `aura://` row would drop a link nothing outside Aura can open.
        guard let dragURL, !isFolder, !dragURL.isOraInternal else {
            let item = NSPasteboardItem()
            item.setString(rowID.uuidString, forType: .auraTabItem)
            return item
        }
        return TabDragPasteboardWriter(tabID: rowID, url: dragURL, title: dragTitle)
    }

    /// The ghost under the pointer: the row's pixels on an opaque card. SwiftUI draws
    /// into layers, not `drawRect`, so `cacheDisplay` came back empty and the drag had
    /// no visible image at all; the host layer is rendered instead.
    func snapshot() -> NSImage {
        let blank = NSImage(size: NSSize(width: 1, height: 1))
        guard let host = hostingAncestor, let hostLayer = host.layer, bounds.width > 1, bounds.height > 1
        else { return blank }
        let rect = convert(bounds, to: host)
        let scale = window?.backingScaleFactor ?? 2
        let pixelSize = CGSize(width: rect.width * scale, height: rect.height * scale)
        guard let ctx = CGContext(
            data: nil,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return blank }
        ctx.scaleBy(x: scale, y: scale)

        let card = CGPath(
            roundedRect: CGRect(origin: .zero, size: rect.size).insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: Self.cardRadius,
            cornerHeight: Self.cardRadius,
            transform: nil
        )
        ctx.addPath(card)
        ctx.setFillColor(Self.cardFill.cgColor)
        ctx.fillPath()

        // The host layer is flipped (top-left origin) and `render(in:)` keeps that, so
        // the row's top-left corner has to land at the context's top-left.
        ctx.saveGState()
        ctx.addPath(card)
        ctx.clip()
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        hostLayer.render(in: ctx)
        ctx.restoreGState()

        ctx.addPath(card)
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        guard let cgImage = ctx.makeImage() else { return blank }
        return NSImage(cgImage: cgImage, size: rect.size)
    }

    /// `TabItem`'s corner radius, so the ghost is the row lifted off the list.
    private static let cardRadius: CGFloat = 10
    /// Solid, one step lighter than the sidebar, like a hovered row.
    private static var cardFill: NSColor {
        NSColor.windowBackgroundColor.blended(withFraction: 0.12, of: .labelColor) ?? .windowBackgroundColor
    }

    /// The direct superview is SwiftUI's representable wrapper, whose layer holds only
    /// this anchor. The row's own pixels live in the hosting view's layer tree.
    private var hostingAncestor: NSView? {
        var view = superview
        while let current = view {
            if String(describing: type(of: current)).hasPrefix("NSHostingView") { return current }
            view = current.superview
        }
        return window?.contentView
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
        Self.operation(
            for: context,
            carriesURL: session.draggingPasteboard.types?.contains(.URL) == true
        )
    }

    /// Inside Aura the row moves. Outside it is copied, but only when the drag actually
    /// carries an address: `pasteboardWriter()` writes the bare row item for a folder and
    /// for an `aura://` tab, and offering a copy cursor over Finder for one of those
    /// promises a drop that produces nothing.
    nonisolated static func operation(
        for context: NSDraggingContext,
        carriesURL: Bool
    ) -> NSDragOperation {
        if context == .withinApplication { return .move }
        return carriesURL ? .copy : []
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
    let url: URL?
    let title: String
    let onMiddleClick: (() -> Void)?

    func makeNSView(context: Context) -> TabDragSourceNSView {
        let view = TabDragSourceNSView()
        view.rowID = id
        view.isFolder = isFolder
        view.zone = zone
        view.dragURL = url
        view.dragTitle = title
        view.onMiddleClick = onMiddleClick
        view.register()
        return view
    }

    func updateNSView(_ nsView: TabDragSourceNSView, context: Context) {
        nsView.rowID = id
        nsView.isFolder = isFolder
        nsView.zone = zone
        nsView.dragURL = url
        nsView.dragTitle = title
        // Re-read every pass: the closure captures the row's current tab.
        nsView.onMiddleClick = onMiddleClick
    }

    static func dismantleNSView(_ nsView: TabDragSourceNSView, coordinator: ()) {
        nsView.unregister()
    }
}

extension View {
    /// Makes the row draggable and lets the section measure it. The hover report is what
    /// keeps the window from being dragged along with the tab: the pointer is over the
    /// row well before the press, so the sidebar's window drag gesture is already off.
    /// `onMiddleClick` rides along because the same monitor already hit-tests the rows.
    /// `url` and `title` are what the row means to another app; a folder passes neither.
    func tabDragSource(
        id: UUID,
        isFolder: Bool = false,
        in zone: TabDragZone,
        url: URL? = nil,
        title: String = "",
        onMiddleClick: (() -> Void)? = nil
    ) -> some View {
        background(TabDragSourceAnchor(
            id: id,
            isFolder: isFolder,
            zone: zone,
            url: url,
            title: title,
            onMiddleClick: onMiddleClick
        ))
        .onHover { TabDragSession.shared.setPointerOnRow(id, $0) }
    }
}
