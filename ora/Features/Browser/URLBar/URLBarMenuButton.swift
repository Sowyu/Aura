import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The "..." app menu shown in the toolbar and the floating URL bar.
struct URLBarMenuButton: View {
    let foregroundColor: Color
    let onShare: (NSView, NSRect) -> Void

    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var historyManager: HistoryManager
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var privacyMode: PrivacyMode

    @Environment(\.openWindow) private var openWindow

    @Query(sort: [SortDescriptor(\History.lastAccessedAt, order: .reverse)])
    private var histories: [History]

    @State private var menuSourceView: NSView?
    @State private var actions = MenuActionTarget()

    private var cornerRadius: CGFloat {
        if #available(macOS 26, *) {
            return 10
        } else {
            return 6
        }
    }

    private var webView: WKWebView? {
        tabManager.activeTab?.browserPage?.contentView as? WKWebView
    }

    private var recentHistory: [History] {
        guard let containerId = tabManager.activeContainer?.id else { return [] }
        return histories.filter { $0.container?.id == containerId }.prefix(10).map { $0 }
    }

    var body: some View {
        Button {
            showMenu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(foregroundColor.opacity(0.85))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.interactive(cornerRadius: cornerRadius, tint: foregroundColor))
        .help("Menu")
        .background(
            MenuSourceView { nsView in
                menuSourceView = nsView
            }
        )
    }

    // MARK: - Menu

    private func showMenu() {
        guard let sourceView = menuSourceView else { return }

        let target = MenuActionTarget()
        actions = target

        let menu = NSMenu()
        menu.autoenablesItems = false

        // Pinned now: while the menu tracks, the menu's own window is key, so a
        // handler that resolves its target from `NSApp.keyWindow` finds nothing.
        let hostWindow = sourceView.window
        let sections = [
            newItemsSection(target),
            librarySection(target, hostWindow: hostWindow),
            pageSection(target, sourceView: sourceView),
            zoomSection(target),
            appSection(target, hostWindow: hostWindow)
        ]
        for section in sections {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            for item in section {
                menu.addItem(item)
            }
        }

        let point = NSPoint(x: 0, y: sourceView.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: sourceView)
    }

    private func newItemsSection(_ target: MenuActionTarget) -> [NSMenuItem] {
        [
            target.item("New Tab", symbol: "plus", shortcut: KeyboardShortcuts.Tabs.new) {
                NotificationCenter.default.post(name: .showLauncher, object: NSApp.keyWindow)
            },
            target.item("New Window", symbol: "macwindow", shortcut: KeyboardShortcuts.Window.new) {
                openWindow(id: "normal")
            },
            target.item(
                "New Private Window",
                symbol: "eyeglasses",
                shortcut: KeyboardShortcuts.Window.newPrivate
            ) {
                openWindow(id: "private")
            }
        ]
    }

    private func librarySection(_ target: MenuActionTarget, hostWindow: NSWindow?) -> [NSMenuItem] {
        [
            historyItem(target: target),
            target.item("Downloads", symbol: "arrow.down.circle") {
                downloadManager.isShowingDownloadsHistory = true
            },
            target.item("Passwords", symbol: "key.horizontal") {
                openPasswordsWindow()
            },
            target.item("Extensions", symbol: "puzzlepiece.extension") {
                NotificationCenter.default.post(
                    name: .openSettingsTab,
                    object: hostWindow,
                    userInfo: ["tab": SettingsTab.extensions.rawValue]
                )
            }
        ]
    }

    private func pageSection(_ target: MenuActionTarget, sourceView: NSView) -> [NSMenuItem] {
        [
            target.item(
                "Print…",
                symbol: "printer",
                key: "p",
                modifiers: [.command],
                enabled: webView != nil,
                handler: printPage
            ),
            target.item(
                "Save Page As…",
                symbol: "square.and.arrow.down",
                enabled: webView != nil,
                handler: savePageAs
            ),
            target.item("Share link", symbol: "square.and.arrow.up") {
                onShare(sourceView, sourceView.bounds)
            },
            target.item("Find in Page…", symbol: "magnifyingglass", shortcut: KeyboardShortcuts.Edit.find) {
                NotificationCenter.default.post(name: .findInPage, object: NSApp.keyWindow)
            }
        ]
    }

    private func zoomSection(_ target: MenuActionTarget) -> [NSMenuItem] {
        [
            target.item(
                "Zoom In",
                symbol: "plus.magnifyingglass",
                shortcut: KeyboardShortcuts.Zoom.zoomIn,
                enabled: webView != nil
            ) {
                setZoom { min($0 + 0.1, 3.0) }
            },
            target.item(
                "Zoom Out",
                symbol: "minus.magnifyingglass",
                shortcut: KeyboardShortcuts.Zoom.zoomOut,
                enabled: webView != nil
            ) {
                setZoom { max($0 - 0.1, 0.5) }
            },
            target.item(
                "Actual Size",
                symbol: "1.magnifyingglass",
                shortcut: KeyboardShortcuts.Zoom.reset,
                enabled: webView != nil
            ) {
                setZoom { _ in 1.0 }
            }
        ]
    }

    private func appSection(_ target: MenuActionTarget, hostWindow: NSWindow?) -> [NSMenuItem] {
        [
            target.item("Settings", symbol: "gearshape", shortcut: KeyboardShortcuts.App.preferences) {
                NotificationCenter.default.post(name: .openSettingsTab, object: hostWindow)
            },
            target.item("Help", symbol: "questionmark.circle") {
                if let url = URL(string: "https://github.com/Sowyu/Aura") {
                    openInNewTab(url)
                }
            }
        ]
    }

    /// History submenu. There is no all-history window in the app yet, so the
    /// submenu lists recent entries only.
    private func historyItem(target: MenuActionTarget) -> NSMenuItem {
        let item = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let entries = recentHistory
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No recent history", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for entry in entries {
                let title = entry.title.isEmpty ? entry.urlString : entry.title
                submenu.addItem(target.item(title, symbol: nil) {
                    openInNewTab(entry.url)
                })
            }
        }
        item.submenu = submenu
        return item
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
        guard let webView else { return }
        let info = NSPrintInfo.shared
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    private func savePageAs() {
        guard let webView, let tab = tabManager.activeTab else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("com.apple.webarchive")].compactMap { $0 }
        let name = tab.title.isEmpty ? (tab.url.host ?? "page") : tab.title
        panel.nameFieldStringValue = "\(name).webarchive"
        panel.canCreateDirectories = true

        let complete: (URL) -> Void = { destination in
            webView.createWebArchiveData { result in
                guard case let .success(data) = result else { return }
                try? data.write(to: destination)
            }
        }

        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                complete(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            complete(url)
        }
    }
}

// MARK: - Menu plumbing

/// Holds the closures for a popped-up `NSMenu`; menu items only carry a tag.
private final class MenuActionTarget: NSObject {
    private var handlers: [() -> Void] = []

    func item(
        _ title: String,
        symbol: String?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        enabled: Bool = true,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.tag = handlers.count
        item.isEnabled = enabled
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        handlers.append(handler)
        return item
    }

    /// Same as above, but takes the key equivalent from a shortcut definition.
    func item(
        _ title: String,
        symbol: String?,
        shortcut: KeyboardShortcutDefinition,
        enabled: Bool = true,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let chord = shortcut.currentChord
        var flags: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.command) {
            flags.insert(.command)
        }
        if chord.modifiers.contains(.shift) {
            flags.insert(.shift)
        }
        if chord.modifiers.contains(.option) {
            flags.insert(.option)
        }
        if chord.modifiers.contains(.control) {
            flags.insert(.control)
        }
        return item(
            title,
            symbol: symbol,
            key: String(chord.keyEquivalent.character).lowercased(),
            modifiers: flags,
            enabled: enabled,
            handler: handler
        )
    }

    @objc func run(_ sender: NSMenuItem) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }
}

private struct MenuSourceView: NSViewRepresentable {
    let onViewCreated: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        DispatchQueue.main.async {
            onViewCreated(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
