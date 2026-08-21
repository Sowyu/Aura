import AppKit
import Inject
import SwiftUI

struct BrowserView: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(AppState.self) private var appState
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(HistoryManager.self) private var historyManager
    @EnvironmentObject private var privacyMode: PrivacyMode
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(ToolbarManager.self) private var toolbarManager

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

    /// Editing-mode holes in window coordinates: the address pill and, when shown, its
    /// suggestions. Grown by 2pt so the pill's hairline stroke stays sharp.
    private var editingHoles: [CGRect] {
        [appState.urlFieldFrame, appState.urlSuggestionsFrame]
            .filter { !$0.isEmpty }
            .map { $0.insetBy(dx: -2, dy: -2) }
    }

    /// One surface over the whole window while the address field is edited: toolbar row,
    /// sidebar and page blur and dim together, with the field and its suggestions cut out
    /// so they stay sharp and clickable. Clicking the surface ends the edit.
    @ViewBuilder
    private var urlEditingBackdrop: some View {
        if appState.isURLBarEditing {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let holes = editingHoles.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                let cutout = CutoutShape(holes: holes, radius: Self.holeRadius)
                ZStack {
                    BlurEffectView(
                        material: .hudWindow, blendingMode: .withinWindow,
                        isClickThrough: true, holes: holes, holeRadius: Self.holeRadius
                    )
                    Color.black.opacity(0.12)
                        .mask(cutout.fill(style: FillStyle(eoFill: true)))
                }
                .contentShape(.interaction, cutout, eoFill: true)
                .onTapGesture { appState.isURLBarEditing = false }
            }
            .transition(.opacity)
        }
    }

    private static let holeRadius: CGFloat = 15

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // In compact mode the revealed bar joins the stack instead of floating over
                // the page, so it sits flush on the pane and the pane's rounded corners
                // flare into the bar's colour exactly as they do when the bar is pinned.
                if !toolbarManager.isToolbarHidden || toolbarManager.isFloatingToolbarVisible {
                    TopToolbar()
                        .background(WindowDragHandle())
                        .transition(.move(edge: .top))
                        .zIndex(1)
                }
                BrowserSplitView()
            }
            .overlay { urlEditingBackdrop }
            .animation(AnimationSettings.easeOut(0.12), value: appState.isURLBarEditing)
            .animation(AnimationSettings.easeOut(0.15), value: toolbarManager.isToolbarHidden)
            .animation(AnimationSettings.easeOut(0.15), value: toolbarManager.isFloatingToolbarVisible)
            .ignoresSafeArea(.all)
            .auraGlassWindowBackdrop()
            // Window-wide, and mounted only while open: the launcher's backdrop covers
            // the chrome as well as the page.
            .overlay {
                ZStack {
                    if appState.showLauncher, tabManager.activeTab != nil {
                        LauncherView()
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
        .animation(AnimationSettings.easeOut(0.15), value: showFloatingSidebar)
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

/// Compact mode's top edge: a 12pt band at the window edge slides the real toolbar in,
/// and the whole row stays hot while it is up so the pointer can use it.
private struct FloatingTopToolbar: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState
    @Environment(ToolbarManager.self) private var toolbarManager

    /// Lives on the manager rather than in local state so `WindowAccessor` can bring
    /// the native traffic lights back with the row.
    private var isVisible: Bool { toolbarManager.isFloatingToolbarVisible }

    /// A live URL edit, an open menu or the launcher hold the row up no matter where
    /// the pointer went.
    private var isHeld: Bool {
        appState.isURLBarEditing || appState.showLauncher || AuraMenuController.shared.isOpen
    }

    var body: some View {
        // The bar itself renders in BrowserView's stack while `isVisible`; this view only
        // owns the hot zone that flips the flag.
        ZStack(alignment: .top) {
            Color.clear
                .frame(height: GlobalMouseTrackingArea.hotZone)
                .overlay(
                    GlobalMouseTrackingArea(
                        mouseEntered: Binding(
                            get: { isVisible },
                            set: { toolbarManager.isFloatingToolbarVisible = $0 }
                        ),
                        edge: .top,
                        revealedExtent: TopToolbar.rowHeight,
                        isHeld: { isHeld }
                    )
                )
        }
        .animation(AnimationSettings.easeOut(0.15), value: isVisible)
        .onDisappear { toolbarManager.isFloatingToolbarVisible = false }
    }
}

/// The full rect plus the holes; filled even-odd it is everything except the holes.
private struct CutoutShape: Shape {
    let holes: [CGRect]
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for hole in holes {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return path
    }
}
