import Foundation

/// Cross-space tab opening. Lives beside the site-to-space rules that drive most of it.
extension TabManager {
    /// Opens `url` in `container` rather than the active space, so the tab is created
    /// against that space's own data store. `reusingHost` navigates an existing tab for the
    /// same registrable domain instead of stacking a duplicate, which is what a
    /// site-to-space rule wants when the user keeps following links to the same site.
    @discardableResult
    func openTab(
        url: URL,
        in container: TabContainer,
        historyManager: HistoryManager?,
        downloadManager: DownloadManager? = nil,
        focusAfterOpening: Bool = true,
        isPrivate: Bool,
        reusingHost: Bool = false
    ) -> Tab? {
        if reusingHost,
           let domain = registrableDomain(from: url),
           let existing = container.tabs.first(where: { registrableDomain(from: $0.url) == domain })
        {
            existing.loadURL(url.absoluteString)
            if focusAfterOpening {
                activateTab(existing)
            }
            try? modelContext.save()
            return existing
        }

        let tab = addTab(
            url: url,
            container: container,
            favicon: url.host.flatMap { FaviconService.shared.faviconURL(for: $0) },
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: isPrivate,
            activateAfterAdding: focusAfterOpening
        )
        if focusAfterOpening {
            activateTab(tab)
        }
        return tab
    }
}
