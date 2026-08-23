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
        if appState.isURLBarEditing, SettingsStore.shared.addressEditingBlur {
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

    private static let holeRadius: CGFloat = AuraRadius.row

    /// Everything stacked above the content pane. The revealed sidebar and the find bar
    /// hang off this so neither of them covers the bookmarks bar.
    private var chromeRowsHeight: CGFloat {
        (isToolbarRowUp ? TopToolbar.rowHeight : 0)
            + (showsBookmarksBar ? BookmarksBar.rowHeight : 0)
            + (tabManager.offersSessionRestore ? SessionRestoreBar.rowHeight : 0)
    }

    /// The bar hides with the toolbar: on its own under a hidden toolbar it would float
    /// against the window edge with no chrome above it.
    private var showsBookmarksBar: Bool {
        SettingsStore.shared.showBookmarksBar && isToolbarRowUp
    }

    /// Pinned or hover-revealed, the row is the same 38pt of chrome in the same place.
    private var isToolbarRowUp: Bool {
        !toolbarManager.isToolbarHidden || toolbarManager.isFloatingToolbarVisible
    }

    /// ⌘G / ⇧⌘G. With nothing searched yet there is nothing to step to, so this opens
    /// the bar and lets the user type instead.
    private func stepFind(forward: Bool) {
        guard let tab = tabManager.activeTab, tab.browserPage != nil else { return }
        appState.showFinderIn = tab.id
        FindManager.shared.step(in: tab, forward: forward)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // The revealed bar joins the stack instead of floating over the page, so it
                // sits flush on the pane and the pane's rounded corners flare into the bar's
                // colour exactly as they do when the bar is pinned.
                if isToolbarRowUp {
                    TopToolbar()
                        .background(WindowDragHandle())
                        .transition(.move(edge: .top))
                        .zIndex(1)
                }
                // Its own row under the toolbar rather than part of it: the toolbar row
                // balances its two button groups to centre the address field, and a
                // second row inside that measurement would fight it.
                if showsBookmarksBar {
                    BookmarksBar()
                        .transition(.move(edge: .top))
                }
                // Under the saved-pages row and above the page, the same band of chrome.
                // Shows only until the user answers it, and only in the window whose
                // launch policy is waiting on that answer.
                if tabManager.offersSessionRestore {
                    SessionRestoreBar()
                        .transition(.move(edge: .top))
                }
                BrowserSplitView()
            }
            .overlay { urlEditingBackdrop }
            .animation(AnimationSettings.easeOut(0.12), value: appState.isURLBarEditing)
            .animation(AnimationSettings.easeOut(0.15), value: toolbarManager.isToolbarHidden)
            .animation(AnimationSettings.easeOut(0.15), value: toolbarManager.isFloatingToolbarVisible)
            .animation(AnimationSettings.easeOut(0.15), value: showsBookmarksBar)
            .animation(AnimationSettings.easeOut(0.15), value: tabManager.offersSessionRestore)
            .ignoresSafeArea(.all)
            .auraGlassWindowBackdrop()
            .overlay {
                if appState.isFloatingTabSwitchVisible {
                    FloatingTabSwitcher()
                }
            }

            // Inset by the row when the row is up, so the revealed sidebar starts under it
            // exactly where the pinned sidebar does instead of covering its buttons.
            if sidebarManager.isSidebarHidden {
                FloatingSidebarOverlay(
                    showFloatingSidebar: $showFloatingSidebar,
                    isMouseOverSidebar: $isMouseOverSidebar,
                    sidebarFraction: sidebarManager.currentFraction,
                    isDownloadsOpen: sidebarManager.panel.isOpen
                )
                .padding(.top, chromeRowsHeight)
            }

            // One hidden-toolbar behaviour, compact or not: the real row hover-reveals.
            if toolbarManager.isToolbarHidden {
                // The whole band of chrome stays hot, not just the toolbar row: the
                // bookmarks and session-restore rows render under it, and a pointer
                // moving down to click a bookmark used to leave the hot rect and hide
                // the chrome out from under itself.
                FloatingTopToolbar(revealedExtent: chromeRowsHeight)
            }

            // Mounted once per window, not per tab: inside the web content view SwiftUI
            // tore the bar down on every tab switch, taking the search term and the
            // keyboard focus with it.
            if let tab = tabManager.activeTab, appState.showFinderIn == tab.id, tab.browserPage != nil {
                FindView(tab: tab)
                    .padding(.top, chromeRowsHeight + 16)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // Above every piece of chrome, not just the page: the launcher centres on the
            // window and dims all of it, so a revealed sidebar or toolbar must not draw
            // over its backdrop. Mounted only while open.
            if appState.showLauncher, tabManager.activeTab != nil {
                LauncherView()
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
        .onReceive(NotificationCenter.default.publisher(for: .findNext)) { _ in
            stepFind(forward: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .findPrevious)) { _ in
            stepFind(forward: false)
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
        .onReceive(NotificationCenter.default.publisher(for: .showHistoryPanel)) { _ in
            withAnimation(AnimationSettings.easeOut(0.15)) {
                sidebarManager.togglePanel(.history)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDownloadsPanel)) { _ in
            withAnimation(AnimationSettings.easeOut(0.15)) {
                sidebarManager.panel = .downloads
            }
        }
        .onChange(of: sidebarManager.panel) { _, panel in
            if sidebarManager.isSidebarHidden {
                if panel.isOpen {
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

/// The top edge while the row is hidden: a 12pt band at the window edge slides the real
/// toolbar in, and every revealed row stays hot while it is up so the pointer can use it.
private struct FloatingTopToolbar: View {
    /// Every row the reveal brings up, measured by `BrowserView`: the toolbar plus the
    /// bookmarks and session-restore rows when they are showing.
    let revealedExtent: CGFloat

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
                // The band only reads the pointer; a click in it belongs to the page.
                .allowsHitTesting(false)
                .overlay(
                    GlobalMouseTrackingArea(
                        mouseEntered: Binding(
                            get: { isVisible },
                            set: { toolbarManager.isFloatingToolbarVisible = $0 }
                        ),
                        edge: .top,
                        revealedExtent: revealedExtent,
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
