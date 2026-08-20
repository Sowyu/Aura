import AppKit
import SwiftUI

// MARK: - URLBar

/// Compact address bar used while the top toolbar is hidden (floating mode).
struct URLBar: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sidebarManager: SidebarManager
    @EnvironmentObject var toolbarManager: ToolbarManager

    let onSidebarToggle: () -> Void

    // MARK: - Helpers

    var buttonForegroundColor: Color {
        tabManager.activeTab.map { URLBarColors.foreground(for: $0).opacity(0.5) } ?? .gray
    }

    private func shareCurrentPage(tab: Tab, sourceView: NSView, sourceRect: NSRect) {
        let url = tab.url
        let title = tab.title.isEmpty ? "Shared from Aura" : tab.title
        let items: [Any] = [title, url]
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = nil
        DispatchQueue.main.async {
            picker.show(relativeTo: sourceRect, of: sourceView, preferredEdge: .minY)
        }
    }

    // MARK: - Body

    var body: some View {
        if let tab = tabManager.activeTab {
            HStack(spacing: 4) {
                if toolbarManager.isToolbarHidden || sidebarManager.sidebarPosition == .secondary {
                    WindowControls(isFullscreen: appState.isFullscreen)
                }

                if sidebarManager.sidebarPosition == .primary {
                    URLBarButton(
                        systemName: "sidebar.left",
                        isEnabled: true,
                        foregroundColor: buttonForegroundColor,
                        action: onSidebarToggle
                    )
                    .oraShortcutHelp("Toggle Sidebar", for: KeyboardShortcuts.App.toggleSidebar)
                }

                // Back button
                URLBarButton(
                    systemName: "chevron.left",
                    isEnabled: tabManager.activeTab?.canGoBack ?? false,
                    foregroundColor: buttonForegroundColor,
                    action: { tabManager.activeTab?.goBack() }
                )
                .oraShortcut(KeyboardShortcuts.Navigation.back)
                .oraShortcutHelp("Go Back", for: KeyboardShortcuts.Navigation.back)

                // Forward button
                URLBarButton(
                    systemName: "chevron.right",
                    isEnabled: tabManager.activeTab?.canGoForward ?? false,
                    foregroundColor: buttonForegroundColor,
                    action: { tabManager.activeTab?.goForward() }
                )
                .oraShortcut(KeyboardShortcuts.Navigation.forward)
                .oraShortcutHelp("Go Forward", for: KeyboardShortcuts.Navigation.forward)

                // Reload button
                URLBarButton(
                    systemName: "arrow.clockwise",
                    isEnabled: tabManager.activeTab != nil,
                    foregroundColor: buttonForegroundColor,
                    action: { tabManager.activeTab?.reload() }
                )
                .oraShortcut(KeyboardShortcuts.Navigation.reload)
                .oraShortcutHelp("Reload This Page", for: KeyboardShortcuts.Navigation.reload)

                URLBarField(
                    tab: tab,
                    foregroundColor: buttonForegroundColor,
                    textColor: URLBarColors.foreground(for: tab)
                )
                .zIndex(1)

                URLBarMenuButton(
                    foregroundColor: buttonForegroundColor,
                    onShare: { sourceView, sourceRect in
                        if let activeTab = tabManager.activeTab {
                            shareCurrentPage(tab: activeTab, sourceView: sourceView, sourceRect: sourceRect)
                        }
                    }
                )

                if sidebarManager.sidebarPosition == .secondary {
                    URLBarButton(
                        systemName: "sidebar.right",
                        isEnabled: true,
                        foregroundColor: buttonForegroundColor,
                        action: onSidebarToggle
                    )
                    .oraShortcutHelp("Toggle Sidebar", for: KeyboardShortcuts.App.toggleSidebar)
                }
            }
            .padding(4)
            .background(
                Rectangle()
                    .fill(tab.backgroundColor)
            )
        }
    }
}

// MARK: - Colors

enum URLBarColors {
    /// Readable text colour for a tab's themed background.
    static func foreground(for tab: Tab) -> Color {
        let nsColor = NSColor(tab.backgroundColor)
        guard let ciColor = CIColor(color: nsColor) else { return .black }
        let luminance = 0.299 * ciColor.red + 0.587 * ciColor.green + 0.114 * ciColor.blue
        return luminance < 0.5 ? .white : .black
    }
}
