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
    private static let buttonSize: CGFloat = 28
    /// Between two buttons that read as one control.
    private static let pairSpacing: CGFloat = 2
    /// Between button groups.
    private static let groupSpacing: CGFloat = 8
    private static let edgeInset: CGFloat = 12
    private static let fieldMaxWidth: CGFloat = 760

    @Environment(\.theme) private var theme
    @Environment(TabManager.self) private var tabManager
    @Environment(AppState.self) private var appState
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @EnvironmentObject private var privacyMode: PrivacyMode

    @Query(sort: [SortDescriptor(\History.lastAccessedAt, order: .reverse)])
    private var histories: [History]

    @State private var historyAnchor: NSView?

    private var buttonForegroundColor: Color {
        theme.foreground.opacity(0.7)
    }

    private var sidebarIcon: String {
        sidebarManager.sidebarPosition == .secondary ? "sidebar.right" : "sidebar.left"
    }

    private var recentHistory: [History] {
        guard let containerId = tabManager.activeContainer?.id else { return [] }
        return histories.filter { $0.container?.id == containerId }.prefix(10).map { $0 }
    }

    var body: some View {
        HStack(spacing: Self.groupSpacing) {
            HStack(spacing: Self.groupSpacing) {
                navigationGroup
                historyGroup
            }

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
        }
        // The traffic lights sit at x = 12/32/52, so the first button starts at 78.
        .padding(.leading, appState.isFullscreen ? Self.edgeInset : Self.trafficLightGap)
        .padding(.trailing, Self.edgeInset)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity)
        .auraGlassChromeForeground()
    }

    // MARK: - Button groups

    private var navigationGroup: some View {
        HStack(spacing: Self.pairSpacing) {
            toolbarButton(
                "chevron.left",
                isEnabled: tabManager.activeTab?.canGoBack ?? false,
                action: { tabManager.activeTab?.goBack() }
            )
            .oraShortcutHelp("Go Back", for: KeyboardShortcuts.Navigation.back)

            toolbarButton(
                "chevron.right",
                isEnabled: tabManager.activeTab?.canGoForward ?? false,
                action: { tabManager.activeTab?.goForward() }
            )
            .oraShortcutHelp("Go Forward", for: KeyboardShortcuts.Navigation.forward)
        }
    }

    private var historyGroup: some View {
        HStack(spacing: Self.groupSpacing) {
            toolbarButton(
                "arrow.clockwise",
                isEnabled: tabManager.activeTab != nil,
                action: { tabManager.activeTab?.reload() }
            )
            .oraShortcutHelp("Reload This Page", for: KeyboardShortcuts.Navigation.reload)

            HStack(spacing: Self.pairSpacing) {
                historyMenu

                toolbarButton("house", isEnabled: tabManager.activeTab != nil, action: goHome)
                    .help("Home")
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

    // MARK: - History

    private var historyMenu: some View {
        Button {
            historyAnchor?.presentAuraMenu(historyItems)
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(buttonForegroundColor.opacity(0.85))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.interactive(cornerRadius: 6, tint: buttonForegroundColor))
        .background(AuraMenuAnchorView { historyAnchor = $0 })
        .frame(width: Self.buttonSize, height: Self.buttonSize)
        .help("Recent History")
    }

    private var historyItems: [AuraMenuItem] {
        guard !recentHistory.isEmpty else { return [.disabled("No recent history")] }
        return recentHistory.map { entry in
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
    @State private var anchor: NSView?

    private static let iconSize = CGSize(width: 16, height: 16)

    var body: some View {
        Button {
            guard let anchor else { return }
            extensionManager.performAction(extensionID: item.id, anchor: anchor)
        } label: {
            icon
                .frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) { badge }
        }
        .buttonStyle(.interactive(cornerRadius: 6, tint: foregroundColor))
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
                .font(.system(size: 13, weight: .medium))
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
                .background(Capsule().fill(Color.accentColor))
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
