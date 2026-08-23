import AppKit
import SwiftData
import SwiftUI

/// Full-width chrome row above both the sidebar and the web content.
/// Rendered by `BrowserView` whenever the toolbar is not hidden.
struct TopToolbar: View {
    /// Leading room reserved for the native window buttons.
    static let trafficLightGap: CGFloat = 78
    static let rowHeight: CGFloat = 38
    /// Height of the tallest control in the row, the address pill.
    private static let contentHeight: CGFloat = 30
    /// Empty space the row leaves above and below its controls. Views placed under
    /// the row subtract it so the visible gap matches the window's other insets.
    static var verticalSlack: CGFloat { (rowHeight - contentHeight) / 2 }
    static let buttonSize: CGFloat = 28
    /// Between two buttons that read as one control.
    private static let pairSpacing: CGFloat = 2
    /// Between button groups.
    private static let groupSpacing: CGFloat = 8
    private static let edgeInset: CGFloat = 12
    private static let fieldMaxWidth: CGFloat = 760

    /// Measured widths of the two button groups including their edge padding. The
    /// extra padding is the difference, so the field always sits on the window's midline.
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    @Environment(\.theme) private var theme
    @Environment(TabManager.self) private var tabManager
    @Environment(AppState.self) private var appState
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @EnvironmentObject private var privacyMode: PrivacyMode

    @State private var historyAnchor: NSView?
    /// Where the back/forward history menus hang from.
    @State private var backAnchor: NSView?
    @State private var forwardAnchor: NSView?

    /// Plain: `URLBarButton` does the one muting for every icon in the row.
    private var buttonForegroundColor: Color {
        theme.foreground
    }

    private var sidebarIcon: String {
        sidebarManager.sidebarPosition == .secondary ? "sidebar.right" : "sidebar.left"
    }

    /// Read when the menu is opened, not on every render: a `@Query` here re-ran the
    /// whole toolbar on every page load, because every navigation writes a history row.
    private func recentHistory() -> [History] {
        guard let containerId = tabManager.activeContainer?.id else { return [] }
        return historyManager.recent(limit: 10, in: containerId)
    }

    var body: some View {
        HStack(spacing: Self.groupSpacing) {
            HStack(spacing: Self.groupSpacing) {
                navigationGroup
                historyGroup
            }
            // The traffic lights sit at x = 12/32/52, so the first button starts at 78.
            .padding(.leading, appState.isFullscreen ? Self.edgeInset : Self.trafficLightGap)
            // Measured before the balancing pad: reading the padded width would feed the
            // pad back into its own input and flip the row between two widths every pass.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
            // Pad the narrower side out to the wider one, so the field centres on the window.
            .padding(.leading, max(0, trailingWidth - leadingWidth))

            Spacer(minLength: Self.groupSpacing)
            URLBarField(
                tab: tabManager.activeTab,
                foregroundColor: theme.foreground.opacity(0.55),
                textColor: theme.foreground
            )
            .frame(maxWidth: Self.fieldMaxWidth)
            // Beats the two Spacers to the free space, so the field reaches its
            // max width and they only split what is left, centring it.
            .layoutPriority(1)
            .zIndex(1)
            Spacer(minLength: Self.groupSpacing)

            HStack(spacing: Self.groupSpacing) {
                JavaScriptBlockedBadge(
                    foregroundColor: buttonForegroundColor,
                    url: tabManager.activeTab?.url,
                    size: Self.buttonSize
                )
                ExtensionToolbarIcons(foregroundColor: buttonForegroundColor)
                appGroup

                Rectangle()
                    .fill(theme.foreground.opacity(0.2))
                    .frame(width: 1, height: 16)

                windowGroup
            }
            .padding(.trailing, Self.edgeInset)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
            .padding(.trailing, max(0, leadingWidth - trailingWidth))
        }
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity)
        .auraGlassChromeForeground()
    }

    // MARK: - Button groups

    private var navigationGroup: some View {
        HStack(spacing: Self.pairSpacing) {
            navigationButton(.back, forward: false)
                .oraShortcutHelp("Go Back", for: KeyboardShortcuts.Navigation.back)

            navigationButton(.forward, forward: true)
                .oraShortcutHelp("Go Forward", for: KeyboardShortcuts.Navigation.forward)
        }
    }

    /// Back or forward, with the tab's own history list on right-click and press-and-hold,
    /// the way both buttons behave in every other browser.
    private func navigationButton(_ icon: ToolbarIcon, forward: Bool) -> some View {
        URLBarButton(
            icon: icon,
            isEnabled: forward
                ? (tabManager.activeTab?.canGoForward ?? false)
                : (tabManager.activeTab?.canGoBack ?? false),
            foregroundColor: buttonForegroundColor,
            size: Self.buttonSize,
            action: {
                if forward {
                    tabManager.activeTab?.goForward()
                } else {
                    tabManager.activeTab?.goBack()
                }
            },
            longPressAction: {
                let anchor = forward ? forwardAnchor : backAnchor
                anchor?.presentAuraMenu(navigationHistoryItems(forward: forward))
            }
        )
        .background(AuraMenuAnchorView { view in
            if forward {
                forwardAnchor = view
            } else {
                backAnchor = view
            }
        })
        .auraContextMenu { navigationHistoryItems(forward: forward) }
    }

    private var historyGroup: some View {
        HStack(spacing: Self.groupSpacing) {
            toolbarButton(
                .reload,
                isEnabled: tabManager.activeTab != nil,
                action: { tabManager.activeTab?.reload() }
            )
            .oraShortcutHelp("Reload This Page", for: KeyboardShortcuts.Navigation.reload)

            HStack(spacing: Self.pairSpacing) {
                historyMenu

                toolbarButton(.home, isEnabled: tabManager.activeTab != nil, action: goHome)
                    .help("Home")
                    .accessibilityLabel(Text("Home"))
            }
        }
    }

    private var appGroup: some View {
        HStack(spacing: Self.pairSpacing) {
            toolbarButton(
                "gearshape",
                isEnabled: true,
                action: { NotificationCenter.default.post(name: .openSettingsTab, object: nil) }
            )
            .oraShortcutHelp("Settings", for: KeyboardShortcuts.App.preferences)

            URLBarMenuButton(
                foregroundColor: buttonForegroundColor,
                size: Self.buttonSize,
                onShare: { sourceView, sourceRect in
                    if let activeTab = tabManager.activeTab {
                        shareCurrentPage(tab: activeTab, sourceView: sourceView, sourceRect: sourceRect)
                    }
                }
            )
        }
    }

    private var windowGroup: some View {
        HStack(spacing: Self.pairSpacing) {
            toolbarButton(sidebarIcon, isEnabled: true, action: { sidebarManager.toggleSidebar() })
                .oraShortcutHelp("Toggle Sidebar", for: KeyboardShortcuts.App.toggleSidebar)

            if !privacyMode.isPrivate {
                DownloadsWidget()
            }
        }
    }

    private func toolbarButton(
        _ systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        URLBarButton(
            systemName: systemName,
            isEnabled: isEnabled,
            foregroundColor: buttonForegroundColor,
            size: Self.buttonSize,
            action: action
        )
    }

    private func toolbarButton(
        _ icon: ToolbarIcon,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        URLBarButton(
            icon: icon,
            isEnabled: isEnabled,
            foregroundColor: buttonForegroundColor,
            size: Self.buttonSize,
            action: action
        )
    }

    // MARK: - Back/forward history

    /// The list a history menu is drawn from: WebKit's own while the tab has a web view,
    /// and the copy saved with the session once it does not. A hibernated tab and a tab
    /// restored at launch both still have a history worth showing.
    private func navigationHistory(for tab: Tab) -> TabHistorySnapshot {
        if let page = tab.browserPage {
            return page.historySnapshot
        }
        let saved = tabManager.sessionStore.session(for: tab.id)?.historyEntries
        return TabHistorySnapshot.decoded(from: saved) ?? TabHistorySnapshot()
    }

    /// Empty when there is nothing that way, which `AuraMenuController` renders as no
    /// menu at all rather than an empty panel.
    private func navigationHistoryItems(forward: Bool) -> [AuraMenuItem] {
        guard let tab = tabManager.activeTab else { return [] }
        let snapshot = navigationHistory(for: tab)
        // Nearest page first, so the one step the button itself takes sits closest to
        // the pointer.
        let rows = NavigationHistoryMenu.rows(from: forward ? snapshot.forward : snapshot.back)
        return rows.map { row in
            .item(row.title) { travel(to: row, forward: forward, in: tab) }
        }
    }

    /// Goes to one page of the list. Through WebKit while the tab is live, because it
    /// restores that entry's scroll position and form state; re-loading the address is
    /// all a tab without a web view can offer.
    private func travel(to row: NavigationHistoryRow, forward: Bool, in tab: Tab) {
        if let page = tab.browserPage,
           let item = page.backForwardItem(atOffset: forward ? row.steps : -row.steps)
        {
            page.go(to: item)
            return
        }
        guard let url = row.url else { return }
        tab.loadURL(url.absoluteString)
    }

    // MARK: - History

    private var historyMenu: some View {
        Button {
            historyAnchor?.presentAuraMenu(historyItems())
        } label: {
            ToolbarIconView(icon: .history)
                .foregroundColor(buttonForegroundColor.opacity(URLBarButton.enabledOpacity))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.interactive(cornerRadius: URLBarButton.cornerRadius, tint: buttonForegroundColor))
        .background(AuraMenuAnchorView { historyAnchor = $0 })
        .frame(width: Self.buttonSize, height: Self.buttonSize)
        .help("Recent History")
        .accessibilityLabel(Text("Recent History"))
    }

    private func historyItems() -> [AuraMenuItem] {
        let recent = recentHistory()
        guard !recent.isEmpty else { return [.disabled("No recent history")] }
        return recent.map { entry in
            .item(entry.title.isEmpty ? entry.urlString : entry.title) {
                openInNewTab(entry.url)
            }
        }
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

    /// Home is `aura://home` unless the user set an address of their own. Navigating to
    /// the built-in page tears the web view down and hands the tab back to `HomePageView`.
    private func goHome() {
        tabManager.activeTab?.loadURL(SettingsStore.shared.homePageURL.absoluteString)
    }

    private func shareCurrentPage(tab: Tab, sourceView: NSView, sourceRect: NSRect) {
        let title = tab.title.isEmpty ? "Shared from Aura" : tab.title
        let items: [Any] = [title, tab.url]
        let picker = NSSharingServicePicker(items: items)
        DispatchQueue.main.async {
            picker.show(relativeTo: sourceRect, of: sourceView, preferredEdge: .minY)
        }
    }
}

// MARK: - Extension icons

/// Icon row for enabled web extensions, shown next to the address field.
struct ExtensionToolbarIcons: View {
    let foregroundColor: Color

    private let extensionManager = ExtensionManager.shared

    private var enabledExtensions: [InstalledExtension] {
        guard ExtensionManager.isSupported else { return [] }
        return extensionManager.installedExtensions.filter(\.isEnabled)
    }

    var body: some View {
        if !enabledExtensions.isEmpty {
            HStack(spacing: 2) {
                ForEach(enabledExtensions) { item in
                    ExtensionIconButton(item: item, foregroundColor: foregroundColor)
                }
            }
        }
    }
}

private struct ExtensionIconButton: View {
    let item: InstalledExtension
    let foregroundColor: Color

    private let extensionManager = ExtensionManager.shared
    @Environment(\.theme) private var theme
    @State private var anchor: NSView?

    private static let iconSize = CGSize(width: 16, height: 16)

    var body: some View {
        Button {
            guard let anchor else { return }
            extensionManager.performAction(extensionID: item.id, anchor: anchor)
        } label: {
            icon
                // The one muting the rest of the row carries, applied to the extension's
                // own artwork as well as the fallback glyph.
                .opacity(URLBarButton.enabledOpacity)
                .frame(width: TopToolbar.buttonSize, height: TopToolbar.buttonSize)
                .overlay(alignment: .topTrailing) { badge }
        }
        .buttonStyle(.interactive(cornerRadius: URLBarButton.cornerRadius, tint: foregroundColor))
        .background(ExtensionActionAnchor { anchor = $0 })
        .help(item.displayName)
        .accessibilityLabel(Text(item.displayName))
    }

    /// Reading `actionRevision` is what subscribes the button to
    /// `browser.action.setIcon`/`setBadgeText`: the icon and badge themselves are
    /// pulled from WebKit on demand and are not observable on their own.
    private func liveActionIcon() -> NSImage? {
        _ = extensionManager.actionRevision
        return extensionManager.actionIcon(for: item.id, size: Self.iconSize)
    }

    private func liveBadgeText() -> String? {
        _ = extensionManager.actionRevision
        return extensionManager.actionBadgeText(for: item.id)
    }

    @ViewBuilder private var icon: some View {
        // The live action icon wins; the manifest icon is the fallback.
        if let image = liveActionIcon() ?? item.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize.width, height: Self.iconSize.height)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: URLBarButton.iconSize, weight: URLBarButton.iconWeight))
                .foregroundColor(foregroundColor)
        }
    }

    @ViewBuilder private var badge: some View {
        if let text = liveBadgeText() {
            Text(text)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 0.5)
                .background(Capsule().fill(theme.accent))
                .fixedSize()
                .offset(x: 4, y: -2)
        }
    }
}

/// A zero-content `NSView` sitting behind the button, used as the popover anchor.
private struct ExtensionActionAnchor: NSViewRepresentable {
    let onViewCreated: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onViewCreated(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
