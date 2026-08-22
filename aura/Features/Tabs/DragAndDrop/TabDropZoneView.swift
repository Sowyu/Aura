//
//  TabDropZoneView.swift
//  Aura
//
//  Ported from Nook's NookDropZoneHostView.swift (github.com/nook-browser/nook, GPL-3.0).
//  Copyright (c) Nook contributors. Adapted: the zone hit-tests the rows registered
//  against it instead of dividing the pointer offset by a fixed cell height.
//

import AppKit
import SwiftUI

final class TabDropZoneNSView: NSView {
    var zone: TabDragZone = .normal(UUID())

    /// Top-left origin, so the pointer and the row boxes read the same way SwiftUI lays
    /// them out and no coordinate has to be flipped by hand.
    override var isFlipped: Bool { true }

    /// AppKit looks for a drop target by hit-testing, and a view sitting behind the rows
    /// is never the one it finds, so the zone lies over them instead. Outside a drag it
    /// hides from hit-testing entirely and the clicks go to the rows as before.
    override func hitTest(_ point: NSPoint) -> NSView? {
        TabDragSession.shared.isDragging ? super.hitTest(point) : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        TabDragSession.shared.entered(zone)
        updateTarget(sender)
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        TabDragSession.shared.exited(zone)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        TabDragSession.shared.drop(in: zone)
    }

    private func updateTarget(_ sender: any NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        TabDragSession.shared.update(zone, at: point, rows: rows())
    }

    /// Read fresh on every pointer move. A cached table would have to be invalidated on
    /// scroll, on a folder opening, and on every lazy row that comes and goes.
    private func rows() -> [TabDragRow] {
        TabDragSourceRegistry.shared.views(in: zone, window: window).map { view in
            TabDragRow(id: view.rowID, isFolder: view.isFolder, frame: view.convert(view.bounds, to: self))
        }
    }
}

private struct TabDropZoneAnchor: NSViewRepresentable {
    let zone: TabDragZone

    func makeNSView(context: Context) -> TabDropZoneNSView {
        let view = TabDropZoneNSView()
        view.zone = zone
        view.registerForDraggedTypes([.auraTabItem])
        return view
    }

    func updateNSView(_ nsView: TabDropZoneNSView, context: Context) {
        nsView.zone = zone
    }
}

extension View {
    /// Marks the section a dragged row can be dropped into.
    func tabDropZone(_ zone: TabDragZone) -> some View {
        overlay(TabDropZoneAnchor(zone: zone))
    }
}
