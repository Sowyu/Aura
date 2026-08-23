import AppKit
import Foundation

/// The four page-wide commands that hang off both the page context menu and the menu
/// bar. They live together so the two entry points cannot drift apart, and so `OraRoot`'s
/// event table only ever names one function per row.
@MainActor
enum PageTools {
    /// A tab already showing an internal page has no web view, so there is nothing to
    /// take a source, an article, an archive or a screenshot of.
    static func isAvailable(for tab: Tab?) -> Bool {
        guard let tab else { return false }
        return !tab.url.isOraInternal && tab.browserPage != nil
    }

    static func viewSource(for tab: Tab?) {
        openTool(for: tab, address: URL.oraViewSource(of:)) { target in
            "Source of \(target.host ?? target.absoluteString)"
        }
    }

    static func reader(for tab: Tab?) {
        let heading = tab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        openTool(for: tab, address: URL.oraReader(of:)) { target in
            heading.isEmpty ? (target.host ?? "Reader") : heading
        }
    }

    static func savePageAs(_ tab: Tab?) {
        guard let tab, let page = tab.browserPage else { return }
        page.saveWebArchive(named: fileNameSeed(for: tab))
    }

    static func saveScreenshot(_ tab: Tab?) {
        guard let tab, let page = tab.browserPage else { return }
        page.saveFullPageScreenshot(named: fileNameSeed(for: tab))
    }

    // MARK: - Shared

    /// Captures the live document first and only then opens the tab, so the page tool
    /// renders the DOM the user was looking at. The tab opens either way: with no
    /// capture the view falls back to fetching the address, which is still a source
    /// listing, just the server's rather than the browser's.
    private static func openTool(
        for tab: Tab?,
        address: @escaping (URL) -> URL,
        title: @escaping (URL) -> String
    ) {
        guard let tab, isAvailable(for: tab), let page = tab.browserPage else { return }
        let target = tab.url
        page.captureDocumentHTML { html in
            MainActor.assumeIsolated {
                if let html, !html.isEmpty {
                    PageSourceStore.shared.store(html, for: target)
                }
                open(address(target), titled: title(target), from: tab)
            }
        }
    }

    private static func open(_ url: URL, titled title: String, from tab: Tab) {
        guard let tabManager = tab.tabManager, let historyManager = tab.historyManager else { return }
        let opened = tabManager.openTab(
            url: url,
            historyManager: historyManager,
            downloadManager: tab.downloadManager,
            focusAfterOpening: true,
            isPrivate: tab.isPrivate
        )
        // Without this the row reads "view-source", which is the internal address's host.
        guard let opened else { return }
        opened.title = title
        saveOrLog(tabManager.modelContext)
    }

    private static func fileNameSeed(for tab: Tab) -> String {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? (tab.url.host ?? "page") : title
    }
}
