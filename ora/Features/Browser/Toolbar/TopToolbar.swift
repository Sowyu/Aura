import AppKit
import SwiftData
import SwiftUI

/// Full-width chrome row above both the sidebar and the web content.
/// Rendered by `BrowserView` whenever the toolbar is not hidden.
struct TopToolbar: View {
    /// Leading room reserved for the native window buttons.
    static let trafficLightGap: CGFloat = 78

    @Environment(\.theme) private var theme
    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sidebarManager: SidebarManager
    @EnvironmentObject private var historyManager: HistoryManager
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var privacyMode: PrivacyMode

    @Query(sort: [SortDescriptor(\History.lastAccessedAt, order: .reverse)])
    private var histories: [History]

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
        HStack(spacing: 4) {
            if !appState.isFullscreen {
                // Space for the native traffic lights, which WindowAccessor
                // repositions into this row.
                Color.clear.frame(width: Self.trafficLightGap, height: 1)
            }

            URLBarButton(
                systemName: "chevron.left",
                isEnabled: tabManager.activeTab?.canGoBack ?? false,
                foregroundColor: buttonForegroundColor,
                action: { tabManager.activeTab?.goBack() }
            )
            .oraShortcutHelp("Go Back", for: KeyboardShortcuts.Navigation.back)

            URLBarButton(
                systemName: "chevron.right",
                isEnabled: tabManager.activeTab?.canGoForward ?? false,
                foregroundColor: buttonForegroundColor,
                action: { tabManager.activeTab?.goForward() }
            )
            .oraShortcutHelp("Go Forward", for: KeyboardShortcuts.Navigation.forward)

            URLBarButton(
                systemName: "arrow.clockwise",
                isEnabled: tabManager.activeTab != nil,
                foregroundColor: buttonForegroundColor,
                action: { tabManager.activeTab?.reload() }
            )
            .oraShortcutHelp("Reload This Page", for: KeyboardShortcuts.Navigation.reload)

            historyMenu

            URLBarButton(
                systemName: "house",
                isEnabled: tabManager.activeTab != nil,
                foregroundColor: buttonForegroundColor,
                action: goHome
            )
            .help("Home")

            if let tab = tabManager.activeTab {
                URLBarField(
                    tab: tab,
                    foregroundColor: theme.foreground.opacity(0.55),
                    textColor: theme.foreground
                )
                .windowDragDisabled()
                .frame(maxWidth: .infinity)
                .zIndex(1)
            } else {
                Spacer()
            }

            ExtensionToolbarIcons(foregroundColor: buttonForegroundColor)

            URLBarButton(
                systemName: "gearshape",
                isEnabled: true,
                foregroundColor: buttonForegroundColor,
                action: { NotificationCenter.default.post(name: .openSettingsTab, object: nil) }
            )
            .oraShortcutHelp("Settings", for: KeyboardShortcuts.App.preferences)

            URLBarMenuButton(
                foregroundColor: buttonForegroundColor,
                onShare: { sourceView, sourceRect in
                    if let activeTab = tabManager.activeTab {
                        shareCurrentPage(tab: activeTab, sourceView: sourceView, sourceRect: sourceRect)
                    }
                }
            )

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            URLBarButton(
                systemName: sidebarIcon,
                isEnabled: true,
                foregroundColor: buttonForegroundColor,
                action: { sidebarManager.toggleSidebar() }
            )
            .oraShortcutHelp("Toggle Sidebar", for: KeyboardShortcuts.App.toggleSidebar)

            if !privacyMode.isPrivate {
                DownloadsWidget()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.foreground.opacity(0.07))
                .frame(height: 1)
        }
    }

    // MARK: - History

    private var historyMenu: some View {
        Menu {
            if recentHistory.isEmpty {
                Text("No recent history")
            } else {
                ForEach(recentHistory) { entry in
                    Button(entry.title.isEmpty ? entry.urlString : entry.title) {
                        openInNewTab(entry.url)
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(buttonForegroundColor)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .help("Recent History")
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

    // No homepage setting exists yet, so "home" is the default search engine's origin.
    // ponytail: derived home URL, swap for a real setting when one exists
    private func goHome() {
        let engine = SearchEngineService().getDefaultSearchEngine(for: tabManager.activeContainer?.id)
        let origin: URL? = engine
            .flatMap { URL(string: $0.searchURL) }
            .flatMap { url in
                guard let scheme = url.scheme, let host = url.host else { return nil }
                return URL(string: "\(scheme)://\(host)")
            }
        guard let home = origin ?? URL(string: "https://www.google.com") else { return }
        tabManager.activeTab?.loadURL(home.absoluteString)
    }

    private func shareCurrentPage(tab: Tab, sourceView: NSView, sourceRect: NSRect) {
        let title = tab.title.isEmpty ? "Shared from Ora" : tab.title
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

    @StateObject private var extensionManager = ExtensionManager.shared

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

    /// Observed so a `browser.action.setIcon`/`setBadgeText` call redraws the button.
    @ObservedObject private var extensionManager = ExtensionManager.shared
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

    @ViewBuilder private var icon: some View {
        // The live action icon wins; the manifest icon is the fallback.
        if let image = extensionManager.actionIcon(for: item.id, size: Self.iconSize) ?? item.icon {
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
        if let text = extensionManager.actionBadgeText(for: item.id) {
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
