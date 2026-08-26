import Combine
import SwiftUI

struct TabSnapshot {
    let image: NSImage
    let url: String
}

struct FloatingTabSwitcher: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(AppState.self) private var appState
    @EnvironmentObject var keyModifierListener: KeyModifierListener
    @Environment(\.theme) var theme

    @FocusState private var focusedTab: Tab.ID?
    @State private var tabSnapshots: [Tab: TabSnapshot] = [:]
    @State private var isLoadingSnapshots = false
    @State private var mouseHasMoved = false
    @State private var mouseMonitor: Any?

    // MARK: - Constants

    private enum Constants {
        static let previewWidth: CGFloat = 200
        static let previewHeight: CGFloat = 125
    }

    var body: some View {
        ZStack {
            backgroundOverlay
            tabSwitcherContainer
        }
        .onExitCommand {
            closeFloatingTabSwitch()
        }
        .onAppear {
            preloadSnapshots()
            if !recentTabs.isEmpty {
                let to = recentTabs.count == 1 ? 0 : 1
                focusedTab = recentTabs[to].id
            }
            startMouseMonitor()
        }
        .onDisappear {
            stopMouseMonitor()
        }
        .onChange(of: appState.isFloatingTabSwitchVisible) { _, isVisible in
            if isVisible {
                preloadSnapshots()
                if !recentTabs.isEmpty {
                    let to = recentTabs.count == 1 ? 0 : 1
                    focusedTab = recentTabs[to].id
                }
                startMouseMonitor()
            } else {
                stopMouseMonitor()
            }
        }
        .onChange(of: keyModifierListener.modifierFlags) { _, newFlags in
            handleModifierChange(newFlags)
        }
    }

    // MARK: - View Components

    private var backgroundOverlay: some View {
        Color.black.opacity(0.2)
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(AnimationSettings.easeOut(0.15), value: appState.isFloatingTabSwitchVisible)
            .onTapGesture {
                closeFloatingTabSwitch()
            }
    }

    private var tabSwitcherContainer: some View {
        HStack(spacing: 12) {
            if tabManager.activeContainer != nil {
                if recentTabs.isEmpty {
                    ZStack {
                        RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                            .fill(theme.mutedBackground)
                            .frame(width: Constants.previewWidth, height: Constants.previewHeight)

                        Text("There are no active tabs")
                            .font(.system(size: 13))
                            .foregroundColor(theme.mutedForeground)
                    }

                } else {
                    ForEach(recentTabs, id: \.id) { tab in
                        tabPreviewItem(for: tab)
                            .focusEffectDisabled()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(theme.popoverBackground)
        .cornerRadius(AuraRadius.pane)
        .auraFloatingShadow()
        .background(keyboardHandler)
        .overlay(containerBorder)
    }

    private func tabPreviewItem(for tab: Tab) -> some View {
        tabPreview(for: tab)
            .animation(AnimationSettings.easeOut(0.1), value: focusedTab)
            .focusable()
            .focused($focusedTab, equals: tab.id)
    }

    private func tabPreview(for tab: Tab) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            tabPreviewImage(for: tab)

            if focusedTab == tab.id {
                tabTitleBar(for: tab)
            }
        }
        .frame(width: Constants.previewWidth, alignment: .leading)
        .padding(.horizontal, 4)
        .onHover { isHovered in
            if isHovered, mouseHasMoved {
                focusedTab = tab.id
            }
        }
        .onTapGesture {
            activateTab(tab)
        }
    }

    @ViewBuilder
    private func tabPreviewImage(for tab: Tab) -> some View {
        if let snapshot = tabSnapshots[tab] {
            Image(nsImage: snapshot.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Constants.previewWidth, height: Constants.previewHeight)
                .clipped()
                .cornerRadius(AuraRadius.row)
                .drawingGroup()
                .overlay(focusBorder(for: tab))
        } else {
            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                .fill(theme.mutedBackground)
                .frame(width: Constants.previewWidth, height: Constants.previewHeight)
                .overlay(focusBorder(for: tab))
        }
    }

    private func focusBorder(for tab: Tab) -> some View {
        RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
            .stroke(
                focusedTab == tab.id ? theme.accent : theme.border,
                lineWidth: focusedTab == tab.id ? 2 : 1
            )
    }

    private func tabTitleBar(for tab: Tab) -> some View {
        HStack(spacing: 8) {
            FavIcon(
                isWebViewReady: tab.isWebViewReady,
                favicon: tab.favicon,
                faviconLocalFile: tab.faviconLocalFile,
                textColor: theme.foreground,
                isPlayingMedia: tab.isPlayingMedia
            )
            .frame(width: 16, height: 16)

            Text(tab.title)
                .font(.system(size: 13))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var keyboardHandler: some View {
        KeyCaptureView(onKeyDown: { event in
            if event.modifierFlags.contains([.control, .shift]) {
                focusPreviousTab()
            } else if event.modifierFlags.contains(.control) {
                focusNextTab()
                preWarmSnapshotsIfNeeded()
            }
        })
    }

    private var containerBorder: some View {
        RoundedRectangle(cornerRadius: AuraRadius.pane, style: .continuous)
            .stroke(theme.border, lineWidth: 1)
    }

    // MARK: - Computed Properties

    /// Hibernated tabs are listed too: filtering on a live web view emptied the switcher
    /// as soon as the eviction pass ran. They show the placeholder until their snapshot
    /// exists, and selecting one loads it back.
    private var recentTabs: [Tab] {
        guard let activeContainer = tabManager.activeContainer else { return [] }
        return activeContainer.tabs
            .sorted { (lhs: Tab, rhs: Tab) in
                (lhs.lastAccessedAt ?? .distantPast) > (rhs.lastAccessedAt ?? .distantPast)
            }
            .prefix(SettingsStore.shared.maxRecentTabs)
            .map { $0 }
    }

    // MARK: - Methods

    private func focusNextTab() {
        guard let currentFocusedTab = focusedTab,
              let currentIndex = recentTabs.firstIndex(where: { $0.id == currentFocusedTab })
        else {
            focusedTab = recentTabs.first?.id
            return
        }

        let nextIndex = (currentIndex + 1) % recentTabs.count
        focusedTab = recentTabs[nextIndex].id
    }

    private func focusPreviousTab() {
        guard let currentFocusedTab = focusedTab,
              let currentIndex = recentTabs.firstIndex(where: { $0.id == currentFocusedTab })
        else {
            focusedTab = recentTabs.first?.id
            return
        }

        let previousIndex = (currentIndex - 1 + recentTabs.count) % recentTabs.count
        focusedTab = recentTabs[previousIndex].id
    }

    private func activateTab(_ tab: Tab) {
        tabManager.activateTab(tab)
        closeFloatingTabSwitch()
    }

    private func handleModifierChange(_ newFlags: NSEvent.ModifierFlags) {
        guard !newFlags.contains(.control) else { return }

        if let focusedTabId = focusedTab,
           let tab = recentTabs.first(where: { $0.id == focusedTabId }) {
            tabManager.activateTab(tab)
        }
        closeFloatingTabSwitch()
    }

    private func preWarmSnapshotsIfNeeded() {
        if !isLoadingSnapshots, tabSnapshots.count < recentTabs.count {
            preloadSnapshots()
        }
    }

    private func preloadSnapshots() {
        guard !isLoadingSnapshots else { return }
        isLoadingSnapshots = true

        let currentTabs = Set(recentTabs)
        tabSnapshots = tabSnapshots.filter { currentTabs.contains($0.key) }

        let snapshotGroup = DispatchGroup()

        for tab in recentTabs {
            guard tab.isWebViewReady else { continue }

            let currentURL = tab.currentPageURL?.absoluteString ?? ""

            if let existingSnapshot = tabSnapshots[tab],
               existingSnapshot.url == currentURL {
                continue
            }

            snapshotGroup.enter()
            takeSnapshot(for: tab, url: currentURL, group: snapshotGroup)
        }

        snapshotGroup.notify(queue: .main) {
            self.isLoadingSnapshots = false
        }
    }

    private func takeSnapshot(for tab: Tab, url: String, group: DispatchGroup) {
        DispatchQueue.global(qos: .userInteractive).async {
            let config = BrowserSnapshotConfiguration(rect: nil, afterScreenUpdates: false)

            DispatchQueue.main.async {
                tab.takeSnapshot(configuration: config) { image, _ in
                    defer { group.leave() }

                    guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        return
                    }

                    // Preserve the original aspect ratio of the snapshot
                    let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
                    let nsImage = NSImage(cgImage: cgImage, size: originalSize)

                    self.tabSnapshots[tab] = TabSnapshot(image: nsImage, url: url)
                }
            }
        }
    }

    private func startMouseMonitor() {
        mouseHasMoved = false
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            mouseHasMoved = true
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
                mouseMonitor = nil
            }
            return event
        }
    }

    private func stopMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func closeFloatingTabSwitch() {
        appState.isFloatingTabSwitchVisible = false
    }
}
