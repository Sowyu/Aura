import AppKit
import SwiftUI

/// Builds the rows shown when the user right-clicks the page. Replaces WebKit's own menu
/// entirely; `AuraWebView` empties that one before it can appear.
@MainActor
struct PageContextMenu {
    let tab: Tab
    let page: BrowserPage
    let info: BrowserContextMenuInfo
    let inspectElement: (() -> Void)?

    private var tabManager: TabManager? { tab.tabManager }
    private var historyManager: HistoryManager? { tab.historyManager }

    func items() -> [AuraMenuItem] {
        Array {
            navigationItems
            linkItems
            imageItems
            selectionItems
            editingItems
            AuraMenuItem.separator
            pageItems
        }
        .tidied()
    }

    // MARK: - Sections

    private var navigationItems: [AuraMenuItem] {
        [
            .item("Back", icon: "chevron.left", shortcut: "⌘[", isDisabled: !page.canGoBack) {
                page.goBack()
            },
            .item("Forward", icon: "chevron.right", shortcut: "⌘]", isDisabled: !page.canGoForward) {
                page.goForward()
            },
            .item("Reload", icon: "arrow.clockwise", shortcut: "⌘R") { page.reload() }
        ]
    }

    private var linkItems: [AuraMenuItem] {
        guard let link = info.link else { return [] }
        return Array {
            AuraMenuItem.separator
            AuraMenuItem.item("Open Link in New Tab", icon: "plus.square.on.square") {
                open(link, focus: false)
            }
            AuraMenuItem.item("Open Link in New Window", icon: "macwindow.badge.plus") {
                WindowFactory.openWindow(with: link)
            }
            spaceItems(for: link)
            AuraMenuItem.item("Copy Link", icon: "link") {
                ClipboardUtils.copyToClipboard(link.absoluteString)
            }
            cleanLinkItem(for: link)
            AuraMenuItem.item("Download Linked File", icon: "arrow.down.circle") {
                page.startDownload(from: link)
            }
        }
    }

    private var imageItems: [AuraMenuItem] {
        guard let image = info.image else { return [] }
        return [
            .separator,
            .item("Open Image in New Tab", icon: "photo") { open(image, focus: false) },
            .item("Copy Image", icon: "doc.on.doc") { page.copyImage(at: image) },
            .item("Copy Image Address", icon: "link") {
                ClipboardUtils.copyToClipboard(image.absoluteString)
            },
            .item("Save Image…", icon: "square.and.arrow.down") { page.startDownload(from: image) }
        ]
    }

    private var selectionItems: [AuraMenuItem] {
        guard info.hasSelection, let selection = info.selection, !info.isEditable else { return [] }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array {
            AuraMenuItem.separator
            AuraMenuItem.item("Copy", icon: "doc.on.doc", shortcut: "⌘C") { sendToPage(#selector(NSText.copy(_:))) }
            searchItem(for: trimmed)
            AuraMenuItem.item("Look Up", icon: "character.book.closed") { lookUp(trimmed) }
        }
    }

    private var editingItems: [AuraMenuItem] {
        guard info.isEditable else { return [] }
        return [
            .separator,
            .item("Cut", icon: "scissors", shortcut: "⌘X", isDisabled: !info.hasSelection) {
                sendToPage(#selector(NSText.cut(_:)))
            },
            .item("Copy", icon: "doc.on.doc", shortcut: "⌘C", isDisabled: !info.hasSelection) {
                sendToPage(#selector(NSText.copy(_:)))
            },
            .item("Paste", icon: "doc.on.clipboard", shortcut: "⌘V") {
                sendToPage(#selector(NSText.paste(_:)))
            },
            .item("Select All", icon: "selection.pin.in.out", shortcut: "⌘A") {
                sendToPage(#selector(NSText.selectAll(_:)))
            }
        ]
    }

    private var pageItems: [AuraMenuItem] {
        Array {
            SpaceMenuItems.alwaysOpen(url: tab.url, in: tab.container)
            reopenInSpaceItems
            AuraMenuItem.separator
            AuraMenuItem.item("Reader", icon: "doc.plaintext", shortcut: "⌥⌘R", isDisabled: !isPageToolAvailable) {
                PageTools.reader(for: tab)
            }
            AuraMenuItem.item(
                "View Source",
                icon: "chevron.left.forwardslash.chevron.right",
                shortcut: "⌥⌘U",
                isDisabled: !isPageToolAvailable
            ) {
                PageTools.viewSource(for: tab)
            }
            AuraMenuItem.separator
            AuraMenuItem.item("Save Page As…", icon: "square.and.arrow.down", shortcut: "⇧⌘S") {
                PageTools.savePageAs(tab)
            }
            AuraMenuItem.item("Save Screenshot…", icon: "camera") { PageTools.saveScreenshot(tab) }
            AuraMenuItem.item("Print…", icon: "printer", shortcut: "⌘P") { page.printPage() }
            if let inspectElement {
                AuraMenuItem.separator
                // WebKit exposes no public inspector API, so this fires the one native menu
                // item that was kept back when WebKit's own menu was emptied.
                AuraMenuItem.item("Inspect Element", icon: "ladybug", action: inspectElement)
            }
        }
    }

    // MARK: - Helpers

    /// Only offered when stripping actually changes the address, so a link that carries
    /// no tracking does not grow a row that copies the same string twice.
    private func cleanLinkItem(for link: URL) -> [AuraMenuItem] {
        let cleaned = LinkCleaner.clean(link)
        guard cleaned != link else { return [] }
        return [
            .item("Copy Link With Clean Parameters", icon: "link.badge.plus") {
                ClipboardUtils.copyToClipboard(cleaned.absoluteString)
            }
        ]
    }

    /// Moves this tab to another space, rather than opening a copy of it there.
    private var reopenInSpaceItems: [AuraMenuItem] {
        guard let tabManager else { return [] }
        let targets = tabManager.fetchContainers().filter { $0.id != tab.container.id }
        guard !targets.isEmpty else { return [] }
        return [
            .submenu("Reopen In Space", icon: "arrow.right.square", items: targets.map { space in
                .item(SpaceMenuItems.label(for: space), icon: space.iconSymbol) {
                    tabManager.moveTabToContainer(tab, toContainer: space)
                }
            })
        ]
    }

    private var isPageToolAvailable: Bool {
        PageTools.isAvailable(for: tab)
    }

    private func spaceItems(for url: URL) -> [AuraMenuItem] {
        guard let tabManager else { return [] }
        return SpaceMenuItems.open(url: url, from: tab, spaces: tabManager.fetchContainers())
    }

    private func searchItem(for query: String) -> [AuraMenuItem] {
        let service = SearchEngineService()
        guard let engine = service.getDefaultSearchEngine(for: tab.container.id),
              let url = service.createSearchURL(for: engine, query: query)
        else {
            return []
        }
        let excerpt = query.count > 24 ? String(query.prefix(24)) + "…" : query
        return [
            .item("Search \(engine.name) for “\(excerpt)”", icon: "magnifyingglass") {
                open(url, focus: true)
            }
        ]
    }

    private func open(_ url: URL, focus: Bool) {
        guard let tabManager, let historyManager else { return }
        tabManager.openTab(
            url: url,
            historyManager: historyManager,
            downloadManager: tab.downloadManager,
            focusAfterOpening: focus,
            isPrivate: tab.isPrivate
        )
    }

    /// Cut, copy and paste in a page field belong to the web view, so they go down the
    /// responder chain exactly as the native menu sent them.
    private func sendToPage(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    private func lookUp(_ text: String) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AuraLookUp"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        NSPerformService("Look Up in Dictionary", pasteboard)
    }
}
