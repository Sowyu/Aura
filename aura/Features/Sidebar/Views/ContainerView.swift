import AppKit
import SwiftUI

struct ContainerView: View {
    let container: TabContainer
    let selectedContainer: String
    let containers: [TabContainer]

    @Environment(\.window) private var window
    @Environment(AppState.self) private var appState
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(ToolbarManager.self) private var toolbarManager
    @Environment(TabManager.self) private var tabManager
    @EnvironmentObject var privacyMode: PrivacyMode
    @Environment(ToastManager.self) private var toastManager

    @State var isDragging = false
    @ObservedObject private var dragSession = TabDragSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if toolbarManager.isToolbarHidden, !toolbarManager.isFloatingToolbarVisible {
                SidebarURLDisplay()
            }
            if !privacyMode.isPrivate {
                // An empty grid still paid the VStack 16pt spacing, leaving a gap under
                // the toolbar, so it only exists while there is something to drop in it.
                if !favoriteTabs.isEmpty || dragSession.isDragging {
                    FavTabsGrid(
                        tabs: favoriteTabs,
                        zone: .fav(container.id),
                        selectedContainerId: selectedContainer,
                        onSelect: selectTab,
                        onFavoriteToggle: toggleFavorite,
                        onClose: removeTab,
                        onDuplicate: duplicateTab,
                        onMoveToContainer: moveTab,
                        containers: containers
                    )
                }
            } else {
                VStack(alignment: .center, spacing: 8) {
                    Text("Private Browsing")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text("Your activity is not being saved")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.1))
                )
                .padding(.horizontal)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // An empty pinned section is pure clutter, so it only exists
                    // while a tab is being dragged.
                    if !privacyMode.isPrivate, !pinnedTabs.isEmpty || dragSession.isDragging {
                        PinnedTabsList(
                            tabs: pinnedTabs,
                            zone: .pinned(container.id),
                            onSelect: selectTab,
                            onPinToggle: togglePin,
                            onFavoriteToggle: toggleFavorite,
                            onClose: removeTab,
                            onDuplicate: duplicateTab,
                            onMoveToContainer: moveTab,
                            containers: containers
                        )
                        .transition(.opacity)
                        Divider()
                    }
                    NormalTabsList(
                        tabs: normalTabs,
                        folders: folders,
                        zone: .normal(container.id),
                        onSelect: selectTab,
                        onPinToggle: togglePin,
                        onFavoriteToggle: toggleFavorite,
                        onClose: removeTab,
                        onDuplicate: duplicateTab,
                        onMoveToContainer: moveTab,
                        onAddNewTab: addNewTab,
                        onNewTabInFolder: addNewTab(in:),
                        containers: containers
                    )
                }
                .animation(AnimationSettings.easeOut(0.12), value: dragSession.isDragging)
                .adaptiveScrollElasticity()
            }
        }
        .modifier(OraWindowDragGesture(isDragging: $isDragging))
        .onChange(of: dragSession.pendingDrop) { _, drop in
            guard let drop, drop.zone.containerID == container.id else { return }
            TabDropCommit.apply(drop, in: container, tabManager: tabManager)
            dragSession.pendingDrop = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTabFolder)) { note in
            // The page view keeps every space alive, so only the visible one may react,
            // and only in the window the command came from. `window` is always nil here:
            // each page is hosted in its own `NSHostingView`, which starts a fresh
            // environment, so the key window has to stand in on both ends of the post.
            guard WindowEventScope.windowOrKey.accepts(note, window: window) else { return }
            guard tabManager.activeContainer?.id == container.id else { return }
            tabManager.createFolderForRenaming()
        }
    }

    private var favoriteTabs: [Tab] {
        return container.tabs
            .filter { $0.type == .fav }
            .sorted(by: { $0.order > $1.order })
    }

    private var pinnedTabs: [Tab] {
        return container.tabs
            .filter { $0.type == .pinned }
            .sorted(by: { $0.order > $1.order })
    }

    /// Foldered tabs render inside their folder, so they are not top-level rows.
    private var normalTabs: [Tab] {
        return container.tabs
            .filter { $0.type == .normal && $0.folder == nil }
            .sorted(by: { $0.order > $1.order })
    }

    private var folders: [Folder] {
        return container.folders.sorted(by: { $0.order > $1.order })
    }

    private func addNewTab() {
        tabManager.openHomeTab(
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: privacyMode.isPrivate
        )
    }

    private func addNewTab(in folder: Folder) {
        tabManager.addTab(
            in: folder,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: privacyMode.isPrivate
        )
    }

    private func removeTab(_ tab: Tab) {
        tabManager.closeTab(tab: tab)
    }

    private func togglePin(_ tab: Tab) {
        tabManager.togglePinTab(tab)
    }

    private func toggleFavorite(_ tab: Tab) {
        tabManager.toggleFavTab(tab)
    }

    private func selectTab(_ tab: Tab) {
        tabManager.activateTab(tab)
    }

    private func moveTab(
        _ tab: Tab,
        _ newContainer: TabContainer
    ) {
        tabManager
            .moveTabToContainer(
                tab,
                toContainer: newContainer
            )
        toastManager.show(
            "Moved to \(newContainer.emoji) \(newContainer.name)",
            icon: .system("arrow.right.arrow.left")
        )
    }

    private func duplicateTab(_ tab: Tab) {
        tabManager.duplicateTab(tab)
    }
}

private struct OraWindowDragGesture: ViewModifier {
    @Binding var isDragging: Bool
    @ObservedObject private var dragSession = TabDragSession.shared

    /// Masking the gesture rather than swapping it out: the old `if` rebuilt the whole
    /// sidebar the first time a tab was dragged, and never gave window dragging back.
    private var mask: GestureMask {
        isDragging || dragSession.pointerOnRow || dragSession.isDragging ? .subviews : .all
    }

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 15.0, *) {
                content.gesture(WindowDragGesture(), including: mask)
            } else {
                content.gesture(BackportWindowDragGesture(isDragging: $isDragging), including: mask)
            }
        }
    }
}

private struct BackportWindowDragGesture: Gesture {
    @Binding var isDragging: Bool

    struct Value: Equatable {
        static func == (lhs: Value, rhs: Value) -> Bool {
            true
        }
    }

    init(isDragging: Binding<Bool>) {
        self._isDragging = isDragging
    }

    var body: some Gesture<Value> {
        DragGesture()
            .onChanged { _ in
                // Makes intent cleaner, if we're dragging, then just return
                // Maybe some other case needs to be watched for here
                guard !isDragging else {
                    return
                }
                guard let win = NSApp.keyWindow, let event = NSApp.currentEvent else {
                    return
                }

                win.performDrag(with: event)
            }
            .map { _ in Value() }
    }
}
