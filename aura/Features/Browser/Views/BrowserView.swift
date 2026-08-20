import AppKit
import Inject
import SwiftUI

struct BrowserView: View {
    @Environment(\.theme) var theme
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var historyManager: HistoryManager
    @EnvironmentObject private var privacyMode: PrivacyMode
    @EnvironmentObject private var sidebarManager: SidebarManager
    @EnvironmentObject private var toolbarManager: ToolbarManager

    @ObserveInjection var inject

    @State private var isMouseOverURLBar = false
    @State private var showFloatingURLBar = false
    @State private var isMouseOverSidebar = false
    @State private var showFloatingSidebar = false

    // MARK: - Sidebar mouse shield

    private static let removeShieldJS = "document.getElementById('ora-sb-shield')?.remove();"

    private var clampedSidebarFraction: CGFloat {
        min(
            max(
                sidebarManager.currentFraction.value,
                FloatingSidebarOverlay.minFraction
            ),
            FloatingSidebarOverlay.maxFraction
        )
    }

    /// Injects/removes a transparent shield div in the web page to block
    /// hover effects and cursor changes behind the floating sidebar.
    private func injectSidebarMouseShield(visible: Bool) {
        guard let activeTab = tabManager.activeTab else { return }
        if visible {
            let side = sidebarManager.sidebarPosition == .primary ? "left" : "right"
            let widthVW = clampedSidebarFraction * 100
            activeTab.evaluateJavaScript(
                """
                var e = document.getElementById('ora-sb-shield');
                if (e) e.remove();
                var d = document.createElement('div');
                d.id = 'ora-sb-shield';
                d.style.position = 'fixed';
                d.style.top = '0';
                d.style.\(side) = '0';
                d.style.width = '\(widthVW)vw';
                d.style.height = '100vh';
                d.style.zIndex = '2147483647';
                d.style.pointerEvents = 'auto';
                d.style.cursor = 'default';
                document.documentElement.appendChild(d);
                """
            )
        } else {
            activeTab.evaluateJavaScript(Self.removeShieldJS)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if !toolbarManager.isToolbarHidden {
                    TopToolbar()
                        .background(WindowDragHandle())
                        .zIndex(1)
                }
                BrowserSplitView()
            }
            .animation(.easeOut(duration: 0.15), value: toolbarManager.isToolbarHidden)
            .ignoresSafeArea(.all)
            .background(theme.subtleWindowBackgroundColor)
            .background(
                BlurEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                    .ignoresSafeArea(.all)
            )
            .overlayPreferenceValue(ContentPaneBoundsKey.self) { paneAnchor in
                GeometryReader { proxy in
                    if appState.showLauncher, tabManager.activeTab != nil {
                        LauncherView(contentPane: paneAnchor.map { proxy[$0] })
                    }
                    if appState.isFloatingTabSwitchVisible {
                        FloatingTabSwitcher()
                    }
                }
            }

            if sidebarManager.isSidebarHidden {
                FloatingSidebarOverlay(
                    showFloatingSidebar: $showFloatingSidebar,
                    isMouseOverSidebar: $isMouseOverSidebar,
                    sidebarFraction: sidebarManager.currentFraction,
                    isDownloadsOpen: downloadManager.isShowingDownloadsHistory
                )
            }

            if toolbarManager.isToolbarHidden, sidebarManager.isCompactEnabled {
                FloatingTopToolbar()
            } else if toolbarManager.isToolbarHidden, sidebarManager.sidebarPosition != .primary {
                FloatingURLBar(
                    showFloatingURLBar: $showFloatingURLBar,
                    isMouseOverURLBar: $isMouseOverURLBar
                )
            }

            // Last in the stack so every menu draws over the chrome and the page. Renders
            // nothing and installs no event monitors until a menu is actually open.
            AuraMenuHost()
        }
        .edgesIgnoringSafeArea(.all)
        .enableInjection()
        .animation(.easeOut(duration: 0.1), value: showFloatingSidebar)
        .onChange(of: showFloatingSidebar) { _, visible in
            injectSidebarMouseShield(visible: visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            sidebarManager.toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebarPosition)) { _ in
            sidebarManager.toggleSidebarPosition()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCompactMode)) { _ in
            sidebarManager.setCompactEnabled(!sidebarManager.isCompactEnabled, toolbar: toolbarManager)
        }
        .onChange(of: downloadManager.isShowingDownloadsHistory) { _, isOpen in
            if sidebarManager.isSidebarHidden {
                if isOpen {
                    showFloatingSidebar = true
                } else if !isMouseOverSidebar {
                    showFloatingSidebar = false
                }
            }
        }
        .onChange(of: tabManager.activeTab) { oldTab, newTab in
            if showFloatingSidebar {
                oldTab?.evaluateJavaScript(Self.removeShieldJS)
                injectSidebarMouseShield(visible: true)
            }
            if let tab = newTab, !tab.isWebViewReady {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    tab.restoreTransientState(
                        historyManager: historyManager,
                        downloadManager: downloadManager,
                        tabManager: tabManager,
                        isPrivate: privacyMode.isPrivate
                    )
                }
            }
        }
        .onAppear {
            // Compact mode's hidden flags live in their own defaults keys, so a fresh
            // window reconciles them with the persisted compact settings.
            sidebarManager.applyCompactModeIfEnabled(toolbar: toolbarManager)
            if let tab = tabManager.activeTab, !tab.isWebViewReady {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    tab.restoreTransientState(
                        historyManager: historyManager,
                        downloadManager: downloadManager,
                        tabManager: tabManager,
                        isPrivate: privacyMode.isPrivate
                    )
                }
            }
        }
    }
}

/// Compact mode's top edge: a 4pt strip that slides the real toolbar in on hover
/// and lets it go once the pointer leaves both the strip and the toolbar itself.
private struct FloatingTopToolbar: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var toolbarManager: ToolbarManager

    /// Lives on the manager rather than in local state so `WindowAccessor` can bring
    /// the native traffic lights back with the row.
    private var isVisible: Bool { toolbarManager.isFloatingToolbarVisible }

    /// While shown, the toolbar row is the hover target, so leaving it hides again.
    private var stripHeight: CGFloat { isVisible ? TopToolbar.rowHeight : 4 }

    var body: some View {
        ZStack(alignment: .top) {
            if isVisible {
                // Opaque, not blurred: the row sits over live page content, and the
                // traffic lights AppKit draws into it are opaque anyway.
                TopToolbar()
                    .background(theme.subtleWindowBackgroundColor)
                    .background(theme.background)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.foreground.opacity(0.08))
                            .frame(height: 1)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    .transition(.move(edge: .top))
                    .zIndex(1)
            }

            Color.clear
                .frame(height: stripHeight)
                .overlay(
                    GlobalMouseTrackingArea(
                        mouseEntered: Binding(
                            get: { isVisible },
                            set: { entered in
                                // A live URL edit must not yank the row away. An open menu
                                // swallows mouse-moved events, so it holds by itself.
                                if !entered, appState.isURLBarEditing { return }
                                toolbarManager.isFloatingToolbarVisible = entered
                            }
                        ),
                        edge: .top,
                        padding: stripHeight,
                        slack: 8
                    )
                    .id(stripHeight)
                )
        }
        .animation(.easeOut(duration: 0.15), value: isVisible)
        .onDisappear { toolbarManager.isFloatingToolbarVisible = false }
    }
}
