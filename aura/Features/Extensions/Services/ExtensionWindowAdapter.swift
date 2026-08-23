import AppKit
import Foundation
@preconcurrency import WebKit

/// Presents one browser window (an `NSWindow` plus the `TabManager` that owns
/// its tabs) to WebKit's extension machinery.
///
/// Every `OraRoot` builds its own `TabManager`, so the pairing is one adapter per
/// window. Private windows are registered too, and report themselves as private:
/// WebKit hides them from every extension that was not granted private access, and
/// `tabs(for:)` refuses to list their tabs as a second line of defence.
///
/// Skipped protocol members: `setWindowState` and `setFrame` (extensions moving
/// or resizing the browser window is not something Aura supports yet).
@available(macOS 15.4, *)
@MainActor
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private static var cache: [ObjectIdentifier: ExtensionWindowAdapter] = [:]

    private(set) weak var window: NSWindow?
    private(set) weak var tabManager: TabManager?
    let isPrivateWindow: Bool

    private init(window: NSWindow, tabManager: TabManager, isPrivate: Bool) {
        self.window = window
        self.tabManager = tabManager
        self.isPrivateWindow = isPrivate
        super.init()
    }

    // MARK: - Registry

    static func adapter(
        for window: NSWindow,
        tabManager: TabManager,
        isPrivate: Bool = false
    ) -> ExtensionWindowAdapter {
        let key = ObjectIdentifier(window)
        if let existing = cache[key], existing.window === window {
            existing.tabManager = tabManager
            return existing
        }
        let adapter = ExtensionWindowAdapter(window: window, tabManager: tabManager, isPrivate: isPrivate)
        cache[key] = adapter
        return adapter
    }

    /// Whether an extension may be told about the tabs in this kind of window.
    ///
    /// A private window is invisible to an extension that was not granted private
    /// access. WebKit filters on the same rule once `hasAccessToPrivateData` is set, so
    /// this is belt and braces: adapters are shared by every loaded extension, and a
    /// missed filter would hand one extension's grant to all of them.
    static func showsTabs(inPrivateWindow: Bool, contextHasPrivateAccess: Bool) -> Bool {
        !inPrivateWindow || contextHasPrivateAccess
    }

    static func adapter(for window: NSWindow) -> ExtensionWindowAdapter? {
        cache[ObjectIdentifier(window)]
    }

    /// Forgets a closed window, returning the adapter so the caller can still
    /// report the close with the object WebKit already has.
    @discardableResult
    static func discardAdapter(for window: NSWindow) -> ExtensionWindowAdapter? {
        cache.removeValue(forKey: ObjectIdentifier(window))
    }

    /// Live adapters, pruning any whose window or tab manager has gone away.
    static func openAdapters() -> [ExtensionWindowAdapter] {
        cache = cache.filter { $0.value.window != nil && $0.value.tabManager != nil }
        return Array(cache.values)
    }

    static func focusedAdapter() -> ExtensionWindowAdapter? {
        let open = openAdapters()
        if let key = NSApp.keyWindow, let match = open.first(where: { $0.window === key }) {
            return match
        }
        if let main = NSApp.mainWindow, let match = open.first(where: { $0.window === main }) {
            return match
        }
        return open.first
    }

    static func adapter(containing tab: Tab) -> ExtensionWindowAdapter? {
        let open = openAdapters()
        if let manager = tab.tabManager, let match = open.first(where: { $0.tabManager === manager }) {
            return match
        }
        return focusedAdapter()
    }

    /// The active space's tabs in the order the sidebar shows them.
    static func orderedTabs(in manager: TabManager) -> [Tab] {
        guard let container = manager.activeContainer else { return [] }
        let byType: (TabType) -> [Tab] = { type in
            container.tabs.filter { $0.type == type }.sorted { $0.order > $1.order }
        }
        return byType(.fav) + byType(.pinned) + byType(.normal)
    }

    // MARK: - WKWebExtensionWindow

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let tabManager, isVisible(to: context) else { return [] }
        return Self.orderedTabs(in: tabManager).map { ExtensionTabAdapter.adapter(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let tab = tabManager?.activeTab, isVisible(to: context) else { return nil }
        return ExtensionTabAdapter.adapter(for: tab)
    }

    /// True when `context` is allowed to know this window's tabs.
    func isVisible(to context: WKWebExtensionContext) -> Bool {
        Self.showsTabs(inPrivateWindow: isPrivateWindow, contextHasPrivateAccess: context.hasAccessToPrivateData)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        isPrivateWindow
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        window?.frame ?? .zero
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}
