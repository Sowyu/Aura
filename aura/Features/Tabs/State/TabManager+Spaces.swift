import Foundation

/// Cross-space tab opening. Lives beside the site-to-space rules that drive most of it.
extension TabManager {
    /// Moves a space `offset` places along the sidebar order and renumbers the whole
    /// list, so the values stay dense and unique no matter what they were before.
    /// `spaces` is the list as the sidebar shows it, i.e. already sorted.
    @discardableResult
    func move(container: TabContainer, by offset: Int, in spaces: [TabContainer]) -> Bool {
        guard let index = spaces.firstIndex(where: { $0.id == container.id }) else { return false }
        let target = index + offset
        guard spaces.indices.contains(target) else { return false }

        var ordered = spaces
        ordered.remove(at: index)
        ordered.insert(container, at: target)
        for (position, space) in ordered.enumerated() {
            space.order = position
        }
        saveOrLog(modelContext)
        return true
    }

    /// Where a freshly made space goes: after every existing one.
    func nextContainerOrder() -> Int {
        (fetchContainers().map(\.order).max() ?? -1) + 1
    }

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
            saveOrLog(modelContext)
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
        return tab
    }
}
