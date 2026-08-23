import AppKit
import Foundation
@preconcurrency import WebKit

/// Presents one Aura `Tab` to WebKit's extension machinery.
///
/// WebKit tracks tabs by object identity, so a `Tab` must always map to the same
/// adapter. `adapter(for:)` is the only way to make one and it caches by tab id.
///
/// Skipped protocol members, all optional and all without an Aura equivalent:
/// reader mode, muting, parent/opener tabs, duplication, zoom factor, locale
/// detection, snapshots and `setSelected` (Aura has single selection only).
@available(macOS 15.4, *)
@MainActor
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    private static var cache: [UUID: ExtensionTabAdapter] = [:]

    let tabID: UUID
    private(set) weak var tab: Tab?

    private init(tab: Tab) {
        self.tabID = tab.id
        self.tab = tab
        super.init()
    }

    static func adapter(for tab: Tab) -> ExtensionTabAdapter {
        pruneStaleAdapters()
        if let existing = cache[tab.id] {
            // SwiftData can hand back a fresh Tab object for the same row; keep
            // the adapter (WebKit knows it) and re-point it at the live tab.
            existing.tab = tab
            return existing
        }
        let adapter = ExtensionTabAdapter(tab: tab)
        cache[tab.id] = adapter
        return adapter
    }

    /// The adapter WebKit is still tracking for `tabID`, if any.
    static func cachedAdapter(for tabID: UUID) -> ExtensionTabAdapter? {
        pruneStaleAdapters()
        return cache[tabID]
    }

    /// Forgets adapters whose tab is gone. `discardAdapter` only covers the closes that
    /// go through `closeTab`; a space deletion and the launch tab policy delete rows in
    /// bulk, and every adapter they left behind kept `tabs.query` reporting a tab that
    /// no longer exists.
    ///
    /// ponytail: linear over the cache on every read, which is one entry per open tab.
    /// Keep an explicit removal list if a window ever holds thousands. A `Tab` object
    /// that deallocates while its row survives loses its adapter too, and WebKit gets a
    /// fresh object the next time it asks; key the cache off the persistent id if that
    /// ever shows up as a duplicated tab.
    private static func pruneStaleAdapters() {
        cache = cache.filter { $0.value.tab?.isDeleted == false }
    }

    /// Forgets a closed tab. Returns the adapter so the caller can still report
    /// the close to WebKit using the object WebKit already has.
    @discardableResult
    static func discardAdapter(for tab: Tab) -> ExtensionTabAdapter? {
        defer { pruneStaleAdapters() }
        return cache.removeValue(forKey: tab.id)
    }

    // MARK: - Identity

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        tab?.browserPage?.contentView as? WKWebView
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.currentPageURL ?? tab?.url
    }

    func title(for context: WKWebExtensionContext) -> String? {
        tab?.title
    }

    /// Nil for a private window an extension has no grant for, so a tab it should not
    /// know about cannot be reached through the window it sits in either.
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let tab, let adapter = ExtensionWindowAdapter.adapter(containing: tab) else { return nil }
        return adapter.isVisible(to: context) ? adapter : nil
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let manager = tab.tabManager else { return 0 }
        return ExtensionWindowAdapter.orderedTabs(in: manager).firstIndex { $0.id == tab.id } ?? 0
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab else { return false }
        return tab.tabManager?.activeTab?.id == tab.id
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        tab?.type == .pinned
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        guard let page = tab?.browserPage else { return true }
        return !page.isLoading
    }

    /// v1 trust model: installing an extension already granted everything it
    /// asked for, so an `activeTab`-style gesture grant is never withheld.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    // MARK: - Navigation

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab else {
            completionHandler(nil)
            return
        }
        if let page = tab.browserPage {
            page.load(URLRequest(url: url))
        } else {
            // No web view yet (aura:// page); this builds one and navigates.
            tab.loadURL(url.absoluteString)
        }
        completionHandler(nil)
    }

    func reload(
        fromOrigin: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if fromOrigin, let webView = webView(for: context) {
            webView.reloadFromOrigin()
        } else {
            tab?.reload()
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.goForward()
        completionHandler(nil)
    }

    // MARK: - Lifecycle

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let tab, let manager = tab.tabManager else {
            completionHandler(nil)
            return
        }
        ExtensionWindowAdapter.adapter(containing: tab)?.window?.makeKeyAndOrderFront(nil)
        manager.activateTab(tab)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let tab, let manager = tab.tabManager else {
            completionHandler(nil)
            return
        }
        manager.closeTab(tab: tab)
        completionHandler(nil)
    }
}
