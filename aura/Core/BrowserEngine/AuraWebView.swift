import AppKit
import WebKit

/// A `WKWebView` with WebKit's own context menu switched off.
///
/// `willOpenMenu` empties the menu before AppKit shows it, so nothing native appears, and
/// the page instead opens an `AuraMenu` built from what the page-side listener reported.
/// One native item survives: Inspect Element has no public API, so its `NSMenuItem` is
/// kept and its action fired later from our own row.
final class AuraWebView: WKWebView {
    /// Called with the right-click's window location and, when WebKit offered one, a closure
    /// that opens the inspector.
    var onContextMenu: ((CGPoint, (() -> Void)?) -> Void)?

    private static let inspectIdentifier = "WKMenuItemIdentifierInspectElement"

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let inspectItem = menu.items.first { $0.identifier?.rawValue == Self.inspectIdentifier }
        menu.removeAllItems()

        // The item is retained by the closure: an NSMenuItem does not keep its own target,
        // and WebKit's is only alive for as long as something holds the item.
        let inspect: (() -> Void)? = inspectItem.flatMap { item in
            guard let action = item.action else { return nil }
            return { NSApp.sendAction(action, to: item.target, from: item) }
        }

        let location = event.locationInWindow
        let handler = onContextMenu
        // AppKit is mid-way through opening its (now empty) menu; presenting on the next
        // turn keeps our panel from being torn down along with it.
        DispatchQueue.main.async { handler?(location, inspect) }
    }
}
