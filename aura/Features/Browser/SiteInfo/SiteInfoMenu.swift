import AppKit
import SwiftUI

/// Everything Aura has decided about the page in front of the user, gathered once so
/// the panel's rows and its tests read the same values.
struct SiteInfoSummary: Equatable {
    /// Registrable domain: the key every per-site rule in Aura is stored under, and the
    /// scope each of them applies to.
    let host: String
    /// Scheme and host as the address bar has them, for example `https://news.bbc.co.uk`.
    let origin: String
    let isSecure: Bool
    let javaScriptAllowed: Bool
    /// nil when the site has no rule of its own and follows the global default.
    let javaScriptRule: Bool?
    let camera: Bool?
    let microphone: Bool?
    let zoom: Double
    /// Name of the space the site is pinned to, when a site-to-space rule exists.
    let spaceName: String?

    /// nil for anything without a site to describe: `about:blank`, a data URL, an
    /// `aura://` page. The panel has nothing to say about those.
    init?(
        url: URL,
        javaScriptRule: Bool?,
        blocksJavaScriptByDefault: Bool,
        permissions: SitePermissionSettings?,
        zoom: Double,
        spaceName: String?
    ) {
        // `aura://home` parses with a host of "home", which would give the panel a site
        // to talk about that nobody can grant anything to.
        guard !url.isOraInternal,
              let host = registrableDomain(from: url),
              let scheme = url.scheme?.lowercased()
        else {
            return nil
        }
        self.host = host
        if let port = url.port {
            origin = "\(scheme)://\(url.host ?? host):\(port)"
        } else {
            origin = "\(scheme)://\(url.host ?? host)"
        }
        isSecure = scheme == "https"
        self.javaScriptRule = javaScriptRule
        javaScriptAllowed = javaScriptRule ?? !blocksJavaScriptByDefault
        camera = permissions?.decision(for: .camera)
        microphone = permissions?.decision(for: .microphone)
        self.zoom = SiteZoom.clamped(zoom)
        self.spaceName = spaceName
    }

    var connectionSummary: String {
        isSecure ? "Connection is encrypted" : "Connection is not encrypted"
    }

    var zoomLabel: String {
        SiteZoom.percentLabel(zoom)
    }

    /// Right-aligned readout for a grant row: what the site may do without opening it.
    static func permissionLabel(_ decision: Bool?) -> String {
        switch decision {
        case true?: return "Allowed"
        case false?: return "Blocked"
        default: return "Ask"
        }
    }
}

/// The address bar's site panel: one place answering what this page is allowed to do.
///
/// Built as menu rows rather than a bespoke popover so it behaves like every other Aura
/// menu, keyboard walking and all. The per-site JavaScript rows come straight from
/// `JavaScriptSiteMenu` so the two never drift apart.
@MainActor
enum SiteInfoMenu {
    static func items(for tab: Tab?, tabManager: TabManager) -> [AuraMenuItem] {
        guard let tab, let summary = summary(for: tab, tabManager: tabManager) else {
            return [.disabled("No site loaded")]
        }

        return [
            .header(summary.host),
            .disabled(
                summary.connectionSummary,
                icon: summary.isSecure ? "lock.fill" : "exclamationmark.triangle"
            ),
            .separator,
            AuraMenuItem(
                kind: .submenu,
                title: "JavaScript",
                icon: "curlybraces",
                shortcut: summary.javaScriptAllowed ? "Allowed" : "Blocked",
                items: JavaScriptSiteMenu.items(for: tab.url)
            ),
            permissionRow(.camera, decision: summary.camera, host: summary.host),
            permissionRow(.microphone, decision: summary.microphone, host: summary.host),
            .separator,
            AuraMenuItem(
                kind: .submenu,
                title: "Zoom",
                icon: "textformat.size",
                shortcut: summary.zoomLabel,
                items: zoomItems(for: tab, summary: summary)
            )
        ]
            + spaceItems(summary: summary)
            + [
                .separator,
                .item("Clear Cookies and Site Data", icon: "trash", isDestructive: true) {
                    clearSiteData(for: tab, host: summary.host)
                }
            ]
    }

    /// Reads the services the panel reports on. Split out so the reducer above stays
    /// free of them.
    static func summary(for tab: Tab, tabManager: TabManager) -> SiteInfoSummary? {
        let spaceID = SiteSpaceRuleService.shared.containerID(for: tab.url)
        let spaceName = spaceID.flatMap { id in
            tabManager.fetchContainers().first { $0.id == id }?.name
        }
        return SiteInfoSummary(
            url: tab.url,
            javaScriptRule: JavaScriptPolicyService.shared.rule(for: tab.url),
            blocksJavaScriptByDefault: JavaScriptPolicyService.shared.blocksByDefault,
            permissions: SettingsStore.shared.sitePermissions(forHost: tab.url.host ?? ""),
            zoom: SiteZoomController.level(for: tab.url),
            spaceName: spaceName
        )
    }

    // MARK: - Rows

    private static func permissionRow(
        _ kind: SitePermissionKind,
        decision: Bool?,
        host: String
    ) -> AuraMenuItem {
        let settings = SettingsStore.shared
        let rows: [AuraMenuItem] = [
            .item("Allow", state: decision == true ? .radioOn : .none) {
                settings.setSitePermission(true, for: kind, host: host)
            },
            .item("Ask Every Time", state: decision == nil ? .radioOn : .none) {
                settings.setSitePermission(nil, for: kind, host: host)
            },
            .item("Block", state: decision == false ? .radioOn : .none) {
                settings.setSitePermission(false, for: kind, host: host)
            }
        ]
        return AuraMenuItem(
            kind: .submenu,
            title: kind.title,
            icon: kind.symbolName,
            shortcut: SiteInfoSummary.permissionLabel(decision),
            items: rows
        )
    }

    private static func zoomItems(for tab: Tab, summary: SiteInfoSummary) -> [AuraMenuItem] {
        [
            .item("Zoom In", icon: "plus.magnifyingglass", shortcut: KeyboardShortcuts.Zoom.zoomIn) {
                SiteZoomController.step(1, for: tab)
            },
            .item("Zoom Out", icon: "minus.magnifyingglass", shortcut: KeyboardShortcuts.Zoom.zoomOut) {
                SiteZoomController.step(-1, for: tab)
            },
            .separator,
            .item(
                "Reset to 100%",
                icon: "arrow.uturn.backward",
                shortcut: KeyboardShortcuts.Zoom.reset,
                isDisabled: SiteZoom.isDefault(summary.zoom)
            ) {
                SiteZoomController.reset(tab)
            }
        ]
    }

    private static func spaceItems(summary: SiteInfoSummary) -> [AuraMenuItem] {
        guard let spaceName = summary.spaceName else { return [] }
        return [
            .separator,
            .disabled("Always opens in \(spaceName)", icon: "square.on.square"),
            .item("Remove Space Rule", icon: "arrow.uturn.backward") {
                SiteSpaceRuleService.shared.removeRule(host: summary.host)
            }
        ]
    }

    /// Clears the site's data in the space the tab browses in, then reloads so the page
    /// shows what a signed-out visit looks like rather than a stale rendering of one.
    private static func clearSiteData(for tab: Tab, host: String) {
        PrivacyService.clearAllData(forHost: host, container: tab.container) {
            DispatchQueue.main.async {
                tab.reload()
                ToastManager.shared.show("Cleared data for \(host)", icon: .system("trash"))
            }
        }
    }
}
