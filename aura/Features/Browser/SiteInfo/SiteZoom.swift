import SwiftUI

/// Page zoom pinned to a site, keyed by registrable domain so every subdomain shares
/// one level. Pure so the ladder and its edges are testable without a web view.
enum SiteZoom {
    // swiftlint:disable:next identifier_name
    static let `default`: Double = 1
    static let minimum: Double = 0.5
    static let maximum: Double = 3

    /// The rungs Safari and Chrome step through, 50% to 300%.
    static let levels: [Double] = [
        minimum, 0.67, 0.75, 0.8, 0.9, `default`, 1.1, 1.25, 1.5, 1.75, 2, 2.5, maximum
    ]

    /// Two levels closer than this are the same rung. Guards the ladder against the
    /// binary representation of 0.67 and friends, and against a hand-edited plist.
    private static let epsilon = 0.005

    static func clamped(_ level: Double) -> Double {
        guard level.isFinite else { return `default` }
        return min(max(level, minimum), maximum)
    }

    static func isDefault(_ level: Double) -> Bool {
        abs(clamped(level) - `default`) < epsilon
    }

    /// One rung up (`direction > 0`) or down. A level that is not on the ladder moves to
    /// the next rung past it rather than snapping to the nearest one first, so a stray
    /// 1.05 cannot swallow a keystroke.
    static func stepped(from level: Double, by direction: Int) -> Double {
        let current = clamped(level)
        guard direction != 0 else { return current }
        if direction > 0 {
            return levels.first { $0 > current + epsilon } ?? maximum
        }
        return levels.last { $0 < current - epsilon } ?? minimum
    }

    /// "120%", the way the address pill and the site info panel label a level.
    static func percentLabel(_ level: Double) -> String {
        "\(Int((clamped(level) * 100).rounded()))%"
    }
}

/// The one place zoom is read, written and pushed at a page.
@MainActor
enum SiteZoomController {
    /// The key a level is stored under.
    ///
    /// A `file://` URL has no host, so without this ⌘+ on a local PDF stored nothing and
    /// did nothing. Every local file shares one level: the size someone reads documents
    /// at is one preference, and a per-file list is one nobody could ever prune. The
    /// colon keeps it out of reach of any real host name.
    static func zoomKey(for url: URL) -> String? {
        url.isFileURL ? "file://" : registrableDomain(from: url)
    }

    /// What `url`'s site is pinned to, or 100%.
    static func level(for url: URL?) -> Double {
        guard let url, let host = zoomKey(for: url) else { return SiteZoom.default }
        return SettingsStore.shared.zoomLevel(forHost: host)
    }

    /// Puts the site's level on the page after a navigation. Always assigns, including
    /// 100%: `pageZoom` belongs to the web view rather than the document, so a tab
    /// leaving a zoomed site would otherwise carry that site's zoom to the next one.
    static func apply(to page: BrowserPage, url: URL?) {
        let level = level(for: url)
        guard abs(page.zoom - level) > 0.001 else { return }
        page.zoom = level
    }

    /// One rung from wherever the site sits now, stored and applied.
    static func step(_ direction: Int, for tab: Tab?) {
        guard let tab else { return }
        set(SiteZoom.stepped(from: level(for: tab.url), by: direction), for: tab)
    }

    static func reset(_ tab: Tab?) {
        guard let tab else { return }
        set(SiteZoom.default, for: tab)
    }

    /// ponytail: only the tab in front is repainted; other live tabs on the same site
    /// pick the level up on their next navigation. Push it to them when someone keeps
    /// two tabs of one site side by side and notices.
    static func set(_ level: Double, for tab: Tab) {
        // `aura://home` parses with a host of "home", so without this the shortcut would
        // write a level for a site that does not exist.
        guard !tab.url.isOraInternal, let host = zoomKey(for: tab.url) else { return }
        SettingsStore.shared.setZoomLevel(level, forHost: host)
        tab.browserPage?.zoom = SiteZoom.clamped(level)
    }
}

/// The current site's zoom, carried in the address pill only while it is not 100%.
/// Clicking it puts the site back to 100%, which is the one thing a zoom readout is
/// ever asked to do.
struct SiteZoomBadge: View {
    let tab: Tab?
    let foregroundColor: Color

    private static let height: CGFloat = 18
    private static let cornerRadius: CGFloat = 5

    var body: some View {
        let level = SiteZoomController.level(for: tab?.url)
        if let tab, !SiteZoom.isDefault(level) {
            Button {
                SiteZoomController.reset(tab)
            } label: {
                Text(SiteZoom.percentLabel(level))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(foregroundColor.opacity(URLBarButton.enabledOpacity))
                    .padding(.horizontal, 6)
                    .frame(height: Self.height)
                    .background(
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .fill(foregroundColor.opacity(0.1))
                    )
            }
            .buttonStyle(.interactive(cornerRadius: Self.cornerRadius, tint: foregroundColor))
            .help("Zoom \(SiteZoom.percentLabel(level)), click to reset")
            .accessibilityLabel(Text("Reset zoom to 100 percent"))
        }
    }
}
