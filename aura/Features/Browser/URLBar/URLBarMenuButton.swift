import AppKit
import SwiftData
import SwiftUI
import WebKit

/// The "..." app menu shown in the toolbar and the floating URL bar.
struct URLBarMenuButton: View {
    let foregroundColor: Color
    var size: CGFloat = 30
    let onShare: (NSView, NSRect) -> Void

    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @EnvironmentObject private var privacyMode: PrivacyMode

    @Environment(\.openWindow) private var openWindow

    @State private var anchor: NSView?

    private var webView: WKWebView? {
        tabManager.activeTab?.browserPage?.contentView as? WKWebView
    }

    /// Fetched when the menu opens. The `@Query` this replaces re-rendered the button on
    /// every history write, i.e. on every navigation in every space.
    private func recentHistory() -> [History] {
        guard let containerId = tabManager.activeContainer?.id else { return [] }
        return historyManager.recent(limit: 10, in: containerId)
    }

    var body: some View {
        Button {
            anchor?.presentAuraMenu(menuItems())
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: URLBarButton.iconSize, weight: .medium))
                .foregroundColor(foregroundColor.opacity(0.85))
                .frame(width: size, height: size)
        }
        .buttonStyle(.interactive(cornerRadius: URLBarButton.cornerRadius, tint: foregroundColor))
        .help("Menu")
        .background(AuraMenuAnchorView { anchor = $0 })
    }

    // MARK: - Menu

    private func menuItems() -> [AuraMenuItem] {
        let hostWindow = anchor?.window
        return newItemsSection()
            + [.separator] + librarySection(hostWindow: hostWindow)
            + [.separator] + pageSection()
            + [.separator] + zoomSection()
            + [.separator] + appSection(hostWindow: hostWindow)
    }

    private func newItemsSection() -> [AuraMenuItem] {
        [
            .item("New Tab", icon: "plus", shortcut: KeyboardShortcuts.Tabs.new) {
                NotificationCenter.default.post(name: .newTab, object: NSApp.keyWindow)
            },
            .item("New Window", icon: "macwindow", shortcut: KeyboardShortcuts.Window.new) {
                openWindow(id: "normal")
            },
            .item("New Private Window", icon: "eyeglasses", shortcut: KeyboardShortcuts.Window.newPrivate) {
                openWindow(id: "private")
            }
        ]
    }

    private func librarySection(hostWindow: NSWindow?) -> [AuraMenuItem] {
        [
            historyItem(hostWindow: hostWindow),
            .item("Downloads", icon: "arrow.down.circle") {
                NotificationCenter.default.post(name: .showDownloadsPanel, object: hostWindow)
            },
            .item("Passwords", icon: "key.horizontal") {
                openPasswordsWindow()
            },
            .item("Extensions", icon: "puzzlepiece.extension") {
                NotificationCenter.default.post(
                    name: .openSettingsTab,
                    object: hostWindow,
                    userInfo: ["tab": SettingsTab.extensions.rawValue]
                )
            }
        ]
    }

    private func pageSection() -> [AuraMenuItem] {
        [
            .item("Print…", icon: "printer", shortcut: "⌘P", isDisabled: webView == nil, action: printPage),
            .item(
                "Save Page As…",
                icon: "square.and.arrow.down",
                isDisabled: webView == nil,
                action: savePageAs
            ),
            .item("Share link", icon: "square.and.arrow.up") {
                guard let anchor else { return }
                onShare(anchor, anchor.bounds)
            },
            .item("Find in Page…", icon: "magnifyingglass", shortcut: KeyboardShortcuts.Edit.find) {
                NotificationCenter.default.post(name: .findInPage, object: NSApp.keyWindow)
            },
            .submenu("JavaScript", icon: "curlybraces", items: JavaScriptSiteMenu.items(for: tabManager.activeTab?.url))
        ]
    }

    private func zoomSection() -> [AuraMenuItem] {
        [
            .item(
                "Zoom In",
                icon: "plus.magnifyingglass",
                shortcut: KeyboardShortcuts.Zoom.zoomIn,
                isDisabled: webView == nil
            ) {
                setZoom { min($0 + 0.1, 3.0) }
            },
            .item(
                "Zoom Out",
                icon: "minus.magnifyingglass",
                shortcut: KeyboardShortcuts.Zoom.zoomOut,
                isDisabled: webView == nil
            ) {
                setZoom { max($0 - 0.1, 0.5) }
            },
            .item(
                "Actual Size",
                icon: "1.magnifyingglass",
                shortcut: KeyboardShortcuts.Zoom.reset,
                isDisabled: webView == nil
            ) {
                setZoom { _ in 1.0 }
            }
        ]
    }

    private func appSection(hostWindow: NSWindow?) -> [AuraMenuItem] {
        [
            .item("Settings", icon: "gearshape", shortcut: KeyboardShortcuts.App.preferences) {
                NotificationCenter.default.post(name: .openSettingsTab, object: hostWindow)
            },
            .item("Help", icon: "questionmark.circle") {
                if let url = URL(string: "https://github.com/Sowyu/Aura") {
                    openInNewTab(url)
                }
            }
        ]
    }

    /// History submenu: the full panel first, then the space's recent entries.
    private func historyItem(hostWindow: NSWindow?) -> AuraMenuItem {
        let showAll = AuraMenuItem.item("Show All History", icon: "clock", shortcut: "⌘Y") {
            NotificationCenter.default.post(name: .showHistoryPanel, object: hostWindow)
        }
        let entries = recentHistory()
        var items: [AuraMenuItem] = [showAll, .separator]
        if entries.isEmpty {
            items.append(.disabled("No recent history"))
        } else {
            items += entries.map { entry in
                .item(entry.title.isEmpty ? entry.urlString : entry.title) {
                    openInNewTab(entry.url)
                }
            }
        }
        return .submenu("History", icon: "clock.arrow.circlepath", items: items)
    }

    // MARK: - Actions

    private func openInNewTab(_ url: URL) {
        tabManager.openTab(
            url: url,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: privacyMode.isPrivate
        )
    }

    private func setZoom(_ transform: (CGFloat) -> CGFloat) {
        guard let webView else { return }
        webView.pageZoom = transform(webView.pageZoom)
    }

    private func printPage() {
        tabManager.activeTab?.browserPage?.printPage()
    }

    private func savePageAs() {
        guard let tab = tabManager.activeTab else { return }
        tab.browserPage?.saveWebArchive(named: tab.title.isEmpty ? (tab.url.host ?? "page") : tab.title)
    }
}
