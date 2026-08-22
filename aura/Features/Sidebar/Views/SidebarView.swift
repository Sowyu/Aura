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

    /// Creation order, so the paged space switcher lands on the same space every time.
    /// Unsorted, SwiftData returns store order, which can change after a save.
    @Query(sort: [SortDescriptor(\TabContainer.createdAt)]) var containers: [TabContainer]

    private let columns = Array(repeating: GridItem(spacing: 10), count: 3)

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
                // Spaces content - pushes back and blurs out while a panel is shown
                spacesContent
                    .frame(width: width)
                    .offset(x: width * 0.12 * progress)
                    .scaleEffect(CGFloat(1.0) - 0.06 * progress, anchor: .center)
                    .opacity(CGFloat(1.0) - 0.5 * progress)
                    .allowsHitTesting(progress < 0.5)

                // Downloads or history - slides in from the leading edge
                panelContent
                    .frame(width: width)
                    .offset(x: -width + width * progress)
                    .shadow(color: .black.opacity(0.08 * Double(progress)), radius: 8, x: 4, y: 0)
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
                NotificationCenter.default.post(name: .newTabFolder, object: window)
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
                        || value.predictedEndTranslation.width > threshold * 2
                    {
                        withAnimation(AnimationSettings.easeOut(0.15)) {
                            sidebarManager.panel = .none
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(AnimationSettings.spring(response: 0.18, dampingFraction: 0.9)) {
                            dragOffset = 0
                        }
                    }
                } else if selectedContainerIndex.wrappedValue == 0 {
                    if -value.translation.width > threshold
                        || -value.predictedEndTranslation.width > threshold * 2
                    {
                        withAnimation(AnimationSettings.easeOut(0.15)) {
                            sidebarManager.panel = .downloads
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(AnimationSettings.spring(response: 0.18, dampingFraction: 0.9)) {
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
            NSPageView(
                selection: selectedContainerIndex,
                pageObjects: containers,
                idKeyPath: \.name
            ) { container in
                ContainerView(
                    container: container,
                    selectedContainer: container.name,
                    containers: containers
                )
                .padding(.horizontal, 10)
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
                    .padding(.horizontal, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !privacyMode.isPrivate {
                HStack {
                    DownloadsWidget()
                    Spacer()
                    ContainerSwitcher(onContainerSelected: onContainerSelected)
                    Spacer()
                    NewContainerButton()
                }
                .padding(.horizontal, 10)
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
