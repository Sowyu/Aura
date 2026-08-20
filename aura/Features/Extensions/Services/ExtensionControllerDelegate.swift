import AppKit
import Foundation
@preconcurrency import WebKit

/// WebKit's callbacks into the browser: which windows and tabs exist, how to open
/// new ones, and where to put an action popup.
///
/// Skipped delegate methods and why:
/// - `openNewWindowUsing`: Aura opens windows through SwiftUI's `openWindow`, which
///   hands back no `NSWindow`, so there is nothing to return to WebKit. Not
///   implementing it makes WebKit report `windows.create` as unsupported instead
///   of hanging.
/// - `openOptionsPageFor`: no options-page UI yet.
/// - `sendMessage`/`connectUsingMessagePort`: native messaging is out of scope.
/// - `didUpdate action:` is implemented, and only bumps a counter the toolbar
///   observes so the icon and badge redraw.
@available(macOS 15.4, *)
extension ExtensionEngine: WKWebExtensionControllerDelegate {
    // MARK: - Windows and tabs

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        ExtensionWindowAdapter.openAdapters()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        ExtensionWindowAdapter.focusedAdapter()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let target = configuration.window as? ExtensionWindowAdapter ?? ExtensionWindowAdapter.focusedAdapter()
        guard let manager = target?.tabManager, let container = manager.activeContainer else {
            completionHandler(nil, ExtensionActionError.noBrowserWindow)
            return
        }

        let url = configuration.url ?? URL(string: "about:blank")
        guard let url else {
            completionHandler(nil, ExtensionActionError.noBrowserWindow)
            return
        }

        target?.window?.makeKeyAndOrderFront(nil)
        // `addTab` reports the open to WebKit through ExtensionManager.tabDidOpen.
        let tab = manager.addTab(
            url: url,
            container: container,
            historyManager: manager.activeTab?.historyManager,
            downloadManager: manager.activeTab?.downloadManager,
            isPrivate: false,
            activateAfterAdding: configuration.shouldBeActive
        )
        completionHandler(ExtensionTabAdapter.adapter(for: tab), nil)
    }

    // MARK: - Permissions

    // v1 trust model: installing an extension grants everything, so every prompt
    // is answered yes with no expiry. Revisit when Settings grows per-permission UI.

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }

    // MARK: - Action popup

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        ExtensionManager.shared.actionDidUpdate()
    }

    /// WebKit builds the popover (web view, sizing, dismissal) for us; all the
    /// browser does is anchor it to the toolbar button that was clicked.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let popover = action.popupPopover else {
            completionHandler(ExtensionActionError.noPopup)
            return
        }
        guard let anchor = ExtensionManager.shared.popupAnchor(for: context.uniqueIdentifier) else {
            completionHandler(ExtensionActionError.noBrowserWindow)
            return
        }

        // Clicking outside dismisses, and NSPopover dismissal calls closePopup(),
        // which unloads the popup web view. Nothing else to tear down.
        popover.behavior = .transient
        // Right-click > Inspect Element inside a popup. Extensions that need APIs WebKit
        // lacks (uBlock Origin: webRequestBlocking) show up as errors there, not as UI.
        action.popupWebView?.isInspectable = true
        // AppKit's y axis points up, so the toolbar button's minY edge is below it.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        completionHandler(nil)
    }
}

enum ExtensionActionError: LocalizedError {
    case noBrowserWindow
    case noPopup

    var errorDescription: String? {
        switch self {
        case .noBrowserWindow:
            return "No browser window is available."
        case .noPopup:
            return "This extension action has no popup."
        }
    }
}
