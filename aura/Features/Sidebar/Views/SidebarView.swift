import AppKit
import Inject
import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(\.theme) private var theme
    @Environment(\.window) var window: NSWindow?
    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(AppState.self) private var appState
    @EnvironmentObject var privacyMode: PrivacyMode
    @Environment(MediaController.self) private var media
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(ToolbarManager.self) private var toolbarManager

    /// Sidebar order, then creation order for spaces that have never been moved (they
    /// all sit at 0). Unsorted, SwiftData returns store order, which can change after a save.
    @Query(sort: [SortDescriptor(\TabContainer.order), SortDescriptor(\TabContainer.createdAt)])
    var containers: [TabContainer]

    private let columns = Array(repeating: GridItem(spacing: 10), count: 3)

    @ObservedObject private var dragSession = TabDragSession.shared
    @Environment(ToastManager.self) private var toastManager

    @ObserveInjection var inject

    @State private var isHoveringSidebarToggle = false

    /// Which panel was last open, so the outgoing panel keeps its own content while it
    /// slides away instead of swapping to the other one mid-animation.
    @State private var lastPanel: SidebarPanel = .none

    /// Panel transition state
    @State private var dragOffset: CGFloat = 0

    private var isShowingPanel: Bool {
        sidebarManager.panel.isOpen
    }

    private var shouldShowMediaWidget: Bool {
        let activeId = tabManager.activeTab?.id
        let others = media.visibleSessions.filter { session in
            guard let activeId else { return true }
            return session.tabID != activeId
        }
        return media.isVisible && !others.isEmpty
    }

    private var selectedContainerIndex: Binding<Int> {
        Binding(
            get: {
                guard let activeContainer = tabManager.activeContainer else {
                    return 0
                }
                return containers.firstIndex { $0.id == activeContainer.id } ?? 0
            },
            set: { newIndex in
                guard newIndex >= 0, newIndex < containers.count else { return }
                tabManager.activateContainer(containers[newIndex])
            }
        )
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = transitionProgress(for: width)

            ZStack(alignment: .leading) {
                // The list stays put. A panel is a flat swap on top of it, not a stack
                // that pushes back and dims.
                spacesContent
                    .frame(width: width)
                    .allowsHitTesting(progress < 0.5)

                // Downloads or history, sliding in over the list from the leading edge.
                panelContent
                    .frame(width: width)
                    .offset(x: -width + width * progress)
                    .allowsHitTesting(progress >= 0.5)
            }
            .clipped()
            // Swipe-to-dismiss gesture on the whole sidebar while a panel is showing
            .simultaneousGesture(panelNavigationGesture(width: width))
        }
        .auraGlassChromeForeground()
        // Behind the content, so a tab row's own catcher takes the click first and this
        // only fires on empty sidebar background.
        .auraBackgroundContextMenu { sidebarContextMenu }
        .onChange(of: sidebarManager.panel) { _, panel in
            if panel.isOpen { lastPanel = panel }
        }
        .enableInjection()
    }

    /// The panel keeps rendering through the dismiss animation, so the switch reads the
    /// last open panel rather than collapsing to downloads as soon as `panel` is `.none`.
    @ViewBuilder
    private var panelContent: some View {
        if sidebarManager.panel == .history || lastPanel == .history {
            HistoryPanelView()
        } else if sidebarManager.panel == .files || lastPanel == .files {
            FilesPanelView()
        } else {
            DownloadsHistoryView()
        }
    }

    // MARK: - Background context menu

    private var favoritesItemTitle: String {
        tabManager.activeTab?.type == .fav
            ? "Remove Selected Tab from Favorites"
            : "Add Selected Tab to Favorites"
    }

    private var sidebarContextMenu: [AuraMenuItem] {
        Array {
            AuraMenuItem.submenu("Compact Mode", icon: "sidebar.left", items: compactModeItems)
            AuraMenuItem.separator
            AuraMenuItem.item("New Tab", icon: "plus", shortcut: KeyboardShortcuts.Tabs.new) {
                NotificationCenter.default.post(name: .showLauncher, object: window)
            }
            AuraMenuItem.item("New Folder", icon: "folder.badge.plus") {
                // Never nil: the receiving page has no window environment of its own, so
                // both ends have to name the same window for the post to be claimed.
                NotificationCenter.default.post(name: .newTabFolder, object: window ?? NSApp.keyWindow)
            }
            AuraMenuItem.separator
            AuraMenuItem.item(
                "Reload Selected Tab",
                icon: "arrow.clockwise",
                shortcut: KeyboardShortcuts.Navigation.reload,
                isDisabled: tabManager.activeTab == nil
            ) {
                tabManager.activeTab?.reload()
            }
            AuraMenuItem.item(
                favoritesItemTitle,
                icon: tabManager.activeTab?.type == .fav ? "star.slash" : "star",
                isDisabled: tabManager.activeTab == nil
            ) {
                if let tab = tabManager.activeTab { tabManager.toggleFavTab(tab) }
            }
            AuraMenuItem.item(
                "Reopen Closed Tab",
                icon: "arrow.uturn.backward",
                shortcut: KeyboardShortcuts.Tabs.restore
            ) {
                NotificationCenter.default.post(name: .restoreLastTab, object: window)
            }
            AuraMenuItem.separator
            AuraMenuItem.item(
                "Tabs on the Right",
                icon: "sidebar.right",
                state: sidebarManager.sidebarPosition == .secondary ? .checked : .none
            ) {
                sidebarManager.toggleSidebarPosition()
            }
            AuraMenuItem.item("Edit Theme…", icon: "paintpalette") {
                NotificationCenter.default.post(
                    name: .openSettingsTab,
                    object: window,
                    userInfo: ["tab": SettingsTab.lookAndFeel.rawValue]
                )
            }
        }
    }

    private var compactModeItems: [AuraMenuItem] {
        var items: [AuraMenuItem] = [
            .item(
                "Enable compact mode",
                state: sidebarManager.isCompactEnabled ? .checked : .none
            ) {
                sidebarManager.setCompactEnabled(!sidebarManager.isCompactEnabled, toolbar: toolbarManager)
            },
            .separator
        ]
        items += CompactModeHides.allCases.map { option in
            .item(
                option.menuTitle,
                state: sidebarManager.compactHides == option ? .radioOn : .none
            ) {
                sidebarManager.setCompactHides(option, toolbar: toolbarManager)
            }
        }
        return items
    }

    /// Computes transition progress (0 = spaces visible, 1 = panel visible)
    /// incorporating both the boolean state and any interactive drag offset.
    private func transitionProgress(for width: CGFloat) -> CGFloat {
        let base: CGFloat = isShowingPanel ? 1.0 : 0.0
        // dragOffset > 0 means dragging right (toward spaces), < 0 means dragging left (toward the panel)
        let dragContribution = -dragOffset / max(width, 1)
        return min(1, max(0, base + dragContribution))
    }

    // MARK: - Gesture

    /// Handles swipe-to-dismiss (right swipe while a panel is up) and
    /// swipe-to-enter (left swipe from first container, which opens downloads).
    private func panelNavigationGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                if isShowingPanel {
                    // Swipe right to dismiss the panel
                    if value.translation.width > 0 {
                        dragOffset = value.translation.width
                    }
                } else if selectedContainerIndex.wrappedValue == 0 {
                    // Swipe left from the first container to show downloads
                    if value.translation.width < 0 {
                        dragOffset = value.translation.width
                    }
                }
            }
            .onEnded { value in
                let threshold = width * 0.25
                if isShowingPanel {
                    if value.translation.width > threshold
                        || value.predictedEndTranslation.width > threshold * 2 {
                        withAnimation(AnimationSettings.easeOut(0.15)) {
                            sidebarManager.panel = .none
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(AnimationSettings.easeOut(0.15)) {
                            dragOffset = 0
                        }
                    }
                } else if selectedContainerIndex.wrappedValue == 0 {
                    if -value.translation.width > threshold
                        || -value.predictedEndTranslation.width > threshold * 2 {
                        withAnimation(AnimationSettings.easeOut(0.15)) {
                            sidebarManager.panel = .downloads
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(AnimationSettings.easeOut(0.15)) {
                            dragOffset = 0
                        }
                    }
                } else {
                    dragOffset = 0
                }
            }
    }

    // MARK: - Spaces Content

    private var spacesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The row owns the traffic lights and nav buttons whenever it is on screen,
            // pinned or revealed, so the sidebar starts flush under it. With the row away
            // the sidebar stands in for it, at the same 38pt, so nothing shifts on reveal.
            if toolbarManager.isToolbarHidden, !toolbarManager.isFloatingToolbarVisible {
                SidebarHeader()
            }
            // Zen's stack, top to bottom: favourites above the space name, so a drag
            // dropped on the name row pins and a drag dropped above it favourites.
            // The grid tracks the active space rather than paging with `NSPageView`;
            // essentials sitting still while spaces slide underneath is the point.
            if !privacyMode.isPrivate, let active = tabManager.activeContainer,
               !favoriteTabs(in: active).isEmpty || dragSession.isDraggingTab {
                FavTabsGrid(
                    tabs: favoriteTabs(in: active),
                    zone: .fav(active.id),
                    onSelect: { tabManager.activateTab($0) },
                    onFavoriteToggle: { tabManager.toggleFavTab($0) },
                    onClose: { tabManager.closeTab(tab: $0) },
                    onDuplicate: { tabManager.duplicateTab($0) },
                    onMoveToContainer: moveFavTab,
                    containers: containers
                )
                .padding(gutter)
                .padding(.bottom, 8)
            }
            // One gutter for every row so they share edges. 8pt on the window edge, to
            // match the pane's inset on the other side, and 0 on the pane side because
            // the pane's own 8pt inset already is the gap.
            if !privacyMode.isPrivate {
                SpaceHeaderRow(containers: containers)
                    .padding(gutter)
                    .padding(.bottom, 8)
            }
            NSPageView(
                selection: selectedContainerIndex,
                pageObjects: containers,
                idKeyPath: \.idString
            ) { container in
                ContainerView(
                    container: container,
                    containers: containers
                )
                .padding(gutter)
                .environment(tabManager)
                .environment(historyManager)
                .environment(downloadManager)
                .environment(appState)
                .environmentObject(privacyMode)
                .environment(toolbarManager)
            }

            if shouldShowMediaWidget {
                GlobalMediaPlayer()
                    .environment(media)
                    .padding(gutter)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !privacyMode.isPrivate {
                HStack {
                    DownloadsWidget()
                    FilesWidget()
                    Spacer()
                    ContainerSwitcher(onContainerSelected: onContainerSelected)
                    Spacer()
                    NewContainerButton()
                }
                .padding(gutter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(
            EdgeInsets(
                top: 0,
                leading: 0,
                bottom: 10,
                trailing: 0
            )
        )
        // Double-click lives on the background layer only. As an ancestor gesture it
        // would hold every tab and button click until the double-click interval expired.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleMaximizeWindow() }
        )
        .auraDropTarget(handleDrop)
    }

    private var gutter: EdgeInsets {
        let paneSide = sidebarManager.sidebarPosition == .secondary
        return EdgeInsets(top: 0, leading: paneSide ? 0 : 8, bottom: 0, trailing: paneSide ? 8 : 0)
    }

    private func favoriteTabs(in container: TabContainer) -> [Tab] {
        container.tabs
            .filter { $0.type == .fav }
            .sorted { $0.order > $1.order }
    }

    /// Same move-with-toast the tab rows use; the grid lives here now, so it needs
    /// its own copy of `ContainerView`'s.
    private func moveFavTab(_ tab: Tab, _ space: TabContainer) {
        tabManager.moveTabToContainer(tab, toContainer: space)
        toastManager.show(
            "Moved to \(space.emoji) \(space.name)",
            icon: .system("arrow.right.arrow.left")
        )
    }

    private func onContainerSelected(container: TabContainer) {
        withAnimation(AnimationSettings.easeOut(0.1)) {
            tabManager.activateContainer(container)
        }
    }

    private func toggleMaximizeWindow() {
        window?.toggleMaximized()
    }
}

// MARK: - Drops

/// Out of the struct body so the view type stays inside the length the rest of the
/// codebase is linted to.
extension SidebarView {
    /// An address, a file or a selection dropped on the sidebar opens a new tab. Aura's
    /// own rows are handled by the drag session that started them, and the drop zones
    /// over the rows claim those first, so anything that reaches here and still says
    /// `.tabItem` landed on empty sidebar background.
    private func handleDrop(_ payload: DropPayload) -> Bool {
        switch payload {
        case .tabItem, .nothing:
            return false
        case let .files(urls):
            FileOpenService.shared.rememberGrants(for: urls)
            for url in urls {
                openInNewTab(url)
            }
            return !urls.isEmpty
        case let .url(url):
            openInNewTab(url)
            return true
        case let .search(text):
            guard let tab = openInNewTab(.oraHome) else { return false }
            tab.loadURL(text)
            return true
        }
    }

    @discardableResult
    private func openInNewTab(_ url: URL) -> Tab? {
        tabManager.openTab(
            url: url,
            historyManager: historyManager,
            downloadManager: downloadManager,
            focusAfterOpening: true,
            isPrivate: privacyMode.isPrivate
        )
    }
}

/// The one empty state both sidebar panels use. Lives here rather than in either panel
/// so history and downloads cannot drift apart again.
struct SidebarPanelEmptyState: View {
    let symbol: String
    let title: String
    var subtitle: String?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(theme.mutedForeground)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedForeground)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}
