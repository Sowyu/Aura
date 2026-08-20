import AppKit
import SwiftUI

struct SidebarURLDisplay: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(TabManager.self) private var tabManager
    @Environment(ToolbarManager.self) private var toolbarManager
    @Environment(ToastManager.self) private var toastManager

    @State private var isHoveringCopy = false
    @State private var isHovering = false
    @State private var showCopiedAnimation = false
    @State private var startWheelAnimation = false

    private func openLauncher() {
        if let tab = tabManager.activeTab {
            appState.launcherSearchText = tab.url.absoluteString
        }
        appState.showLauncher = true
    }

    private func triggerCopy(_ text: String) {
        ClipboardUtils.triggerCopy(
            text,
            showCopiedAnimation: $showCopiedAnimation,
            startWheelAnimation: $startWheelAnimation
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let tab = tabManager.activeTab {
                HStack(spacing: 8) {
                    if tab.isLoading {
                        ProgressView()
                            .tint(theme.foreground.opacity(0.7))
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        if tab.url.scheme != "https" {
                            Image(systemName: "shield.slash")
                                .font(.system(size: 12))
                                .foregroundColor(theme.mutedForeground)
                        }
                    }

                    ZStack(alignment: .leading) {
                        let parts = displayParts(for: tab)
                        HStack(spacing: 0) {
                            Text(parts.host)
                                .font(.system(size: 14))
                                .foregroundColor(theme.mutedForeground)
                            if let title = parts.title {
                                Text(" / \(title)")
                                    .font(.system(size: 14))
                                    .foregroundColor(theme.mutedForeground.opacity(0.6))
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(showCopiedAnimation ? 0 : 1)
                        .offset(y: showCopiedAnimation ? (startWheelAnimation ? -12 : 12) : 0)
                        .animation(.easeOut(duration: 0.2), value: showCopiedAnimation)
                        .animation(.easeOut(duration: 0.2), value: startWheelAnimation)

                        CopiedURLOverlay(
                            foregroundColor: theme.mutedForeground,
                            showCopiedAnimation: $showCopiedAnimation,
                            startWheelAnimation: $startWheelAnimation
                        )
                    }
                }
                Spacer(minLength: 0)

                Button {
                    triggerCopy(tab.url.absoluteString)
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 14))
                        .foregroundColor(isHoveringCopy ? theme.foreground.opacity(0.8) : theme.mutedForeground)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.interactive(cornerRadius: 6))
                .onHover { hovering in
                    isHoveringCopy = hovering
                }
                .animation(.easeOut(duration: 0.1), value: isHoveringCopy)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(theme.mutedForeground)

                Text("Search or enter URL")
                    .font(.system(size: 14))
                    .foregroundColor(theme.mutedForeground)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { openLauncher() }
        .onHover { hovering in
            isHovering = hovering
        }
        .background(
            ConditionallyConcentricRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.invertedSolidWindowBackgroundColor.opacity(isHovering ? 0.11 : 0.07))
        )
        .overlay(
            Button("") { openLauncher() }
                .oraShortcut(KeyboardShortcuts.Address.focus)
                .opacity(0)
                .allowsHitTesting(false)
                .disabled(
                    !toolbarManager.isToolbarHidden || sidebarManager.sidebarPosition != .primary
                )
        )
        .overlay(
            ConditionallyConcentricRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.invertedSolidWindowBackgroundColor.opacity(0.05), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .onReceive(NotificationCenter.default.publisher(for: .copyAddressURL)) { _ in
            guard toolbarManager.isToolbarHidden, sidebarManager.sidebarPosition == .primary else { return }
            if let activeTab = tabManager.activeTab {
                ClipboardUtils.copyWithToast(
                    activeTab.url.absoluteString,
                    toastManager: toastManager
                )
            }
        }
    }

    private func displayParts(for tab: Tab) -> URLDisplayParts {
        URLDisplayUtils.displayParts(url: tab.url, title: tab.title, showFull: toolbarManager.showFullURL)
    }
}
