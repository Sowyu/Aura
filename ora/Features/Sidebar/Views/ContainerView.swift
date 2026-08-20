import AppKit
import SwiftUI

struct ContainerView: View {
    let container: TabContainer
    let selectedContainer: String
    let containers: [TabContainer]

    @Environment(\.window) private var window
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var historyManager: HistoryManager
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var toolbarManager: ToolbarManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var privacyMode: PrivacyMode
    @EnvironmentObject var toastManager: ToastManager

    @State var isDragging = false
    @State private var draggedItem: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if toolbarManager.isToolbarHidden {
                SidebarURLDisplay()
            }
            if !privacyMode.isPrivate {
                // An empty grid still paid the VStack 16pt spacing, leaving a gap under the toolbar.
                if !favoriteTabs.isEmpty {
                    FavTabsGrid(
                        tabs: favoriteTabs,
                        draggedItem: $draggedItem,
                        onDrag: dragTab,
                        selectedContainerId: selectedContainer,
                        onSelect: selectTab,
                        onFavoriteToggle: toggleFavorite,
                        onClose: removeTab,
                        onDuplicate: duplicateTab,
                        onMoveToContainer: moveTab
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
                    if !privacyMode.isPrivate, !pinnedTabs.isEmpty || draggedItem != nil {
                        PinnedTabsList(
                            tabs: pinnedTabs,
                            draggedItem: $draggedItem,
                            onDrag: dragTab,
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
                        draggedItem: $draggedItem,
                        onDrag: dragTab,
                        onSelect: selectTab,
                        onPinToggle: togglePin,
                        onFavoriteToggle: toggleFavorite,
                        onClose: removeTab,
                        onDuplicate: duplicateTab,
                        onMoveToContainer: moveTab,
                        onAddNewTab: addNewTab,
                        onNewTabInFolder: addNewTab(in:)
                    )
                }
                .animation(.easeOut(duration: 0.12), value: draggedItem == nil)
            }
        }
        .modifier(OraWindowDragGesture(isDragging: $isDragging))
        .onReceive(NotificationCenter.default.publisher(for: .newTabFolder)) { note in
            // The page view keeps every space alive, so only the visible one may react,
            // and only in the window the command came from.
            guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
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
        appState.showLauncher = true
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

    private func dragTab(_ tabId: UUID) -> NSItemProvider {
        isDragging = true
        draggedItem = tabId
        let provider = TabItemProvider(object: tabId.uuidString as NSString)
        // Fires when the drag session releases the provider: on drop and on cancel alike
        // (macOS gives SwiftUI no cancel callback), so it doubles as the reset for both.
        provider.didEnd = {
            DispatchQueue.main.async { draggedItem = nil }
        }
        return provider
    }

    private func dropTab(_ tabId: String) {
        isDragging = false
        draggedItem = nil
    }

    private func duplicateTab(_ tab: Tab) {
        tabManager.duplicateTab(tab)
    }
}

private struct OraWindowDragGesture: ViewModifier {
    @Binding var isDragging: Bool

    func body(content: Content) -> some View {
        Group {
            if isDragging {
                content
            } else {
                if #available(macOS 15.0, *) {
                    content.gesture(WindowDragGesture())
                } else {
                    content.gesture(BackportWindowDragGesture(isDragging: $isDragging))
                }
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

class TabItemProvider: NSItemProvider {
    var didEnd: (() -> Void)?
    deinit {
        didEnd?()
    }
}
