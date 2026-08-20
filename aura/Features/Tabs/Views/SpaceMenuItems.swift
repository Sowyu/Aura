import Foundation

/// Space-aware menu rows, shared by the tab row menu and the page context menu so both
/// offer the same wording and the same behaviour.
@MainActor
enum SpaceMenuItems {
    /// A space reads as its SF Symbol when it has one, and as "emoji name" otherwise,
    /// matching how the sidebar labels it.
    static func label(for space: TabContainer) -> String {
        space.emoji.isEmpty ? space.name : "\(space.emoji) \(space.name)"
    }

    /// "Open in <space>" for every space but the one `tab` already lives in. Empty when
    /// there is nowhere else to send it.
    static func open(
        url: URL,
        from tab: Tab,
        title: String = "Open Link in Space",
        spaces: [TabContainer]
    ) -> [AuraMenuItem] {
        let targets = spaces.filter { $0.id != tab.container.id }
        guard !targets.isEmpty,
              let tabManager = tab.tabManager,
              let historyManager = tab.historyManager
        else {
            return []
        }
        return [
            .submenu(title, icon: "square.on.square", items: targets.map { space in
                .item(label(for: space), icon: space.iconSymbol) {
                    tabManager.openTab(
                        url: url,
                        in: space,
                        historyManager: historyManager,
                        downloadManager: tab.downloadManager,
                        isPrivate: tab.isPrivate
                    )
                }
            })
        ]
    }

    /// The site-to-space rule toggle. Checked while the rule already points here, and
    /// selecting it again clears the rule.
    static func alwaysOpen(url: URL, in space: TabContainer) -> [AuraMenuItem] {
        guard let host = registrableDomain(from: url) else { return [] }
        let service = SiteSpaceRuleService.shared
        let isPinned = service.containerID(forHost: host) == space.id
        return [
            .item(
                isPinned ? "Stop Opening \(host) Here" : "Always Open \(host) in This Space",
                icon: "pin",
                state: isPinned ? .checked : .none
            ) {
                if isPinned {
                    service.removeRule(host: host)
                } else {
                    service.setRule(host: host, containerID: space.id)
                }
            }
        ]
    }
}
