import SwiftUI

/// The sidebar's history panel: search, a time-range filter, date-grouped rows and
/// infinite scroll over `HistoryManager.page`.
///
/// Ported from Nook's `SidebarMenuHistoryTab` (`Nook/Components/Sidebar/Menu/
/// SidebarMenuHistoryTab.swift`) by Maciek Bagiński, GPL-3.0. The layout follows Aura's
/// downloads panel so the two read as one control, and the store queries stay Aura's.
struct HistoryPanelView: View {
    @Environment(HistoryManager.self) private var historyManager
    @Environment(TabManager.self) private var tabManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(AppState.self) private var appState
    @Environment(ToolbarManager.self) private var toolbarManager
    @EnvironmentObject private var privacyMode: PrivacyMode
    @Environment(\.theme) private var theme

    /// Big enough that the first screen never needs a second fetch, small enough that
    /// scrolling a year of history stays incremental.
    private static let pageSize = 50

    @State private var searchText = ""
    @State private var range: HistoryRange = .all
    @State private var items: [History] = []
    @State private var hasMore = true
    @State private var isShowingFilters = false
    @State private var isClearHovered = false

    private var containerId: UUID? {
        tabManager.activeContainer?.id
    }

    private var sections: [HistoryGrouping.Section] {
        HistoryGrouping.sections(for: items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            if isShowingFilters {
                filterRow
            }
            content
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 4)
        .background(theme.chromeBackground)
        .background(BlurEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
        .onAppear(perform: reload)
        .onChange(of: searchText) { _, _ in reload() }
        .onChange(of: range) { _, _ in reload() }
        .onChange(of: containerId) { _, _ in reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            // Match SidebarHeader traffic light spacing when the sidebar is primary
            // (the top toolbar draws them itself when it is visible).
            if sidebarManager.sidebarPosition != .secondary, toolbarManager.isToolbarHidden {
                WindowControls(isFullscreen: appState.isFullscreen)
                    .frame(height: 30)
            }

            Text("History")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.foreground)
                .lineLimit(1)

            Spacer()

            if !items.isEmpty {
                Button(action: clearRange) {
                    HStack(spacing: 4) {
                        OraIcons(icon: .brush1, size: .sm, color: isClearHovered ? theme.foreground : .secondary)
                        Text("Clear")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isClearHovered ? theme.foreground : .secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.interactive(cornerRadius: 6))
                .onHover { isClearHovered = $0 }
                .animation(AnimationSettings.easeOut(0.1), value: isClearHovered)
                .help(range == .all ? "Clear all history in this space" : "Clear \(range.title.lowercased())")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    // MARK: - Search and filters

    private var searchBar: some View {
        HStack(spacing: 6) {
            OraInput(
                text: $searchText,
                placeholder: "Search history...",
                size: .md,
                leadingIcon: "magnifyingglass"
            )

            Button {
                withAnimation(AnimationSettings.easeOut(0.1)) { isShowingFilters.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isShowingFilters ? theme.foreground : .secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.interactive(cornerRadius: 8))
            .help("Filter by time")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var filterRow: some View {
        HStack(spacing: 4) {
            ForEach(HistoryRange.allCases) { option in
                Button {
                    range = option
                } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(option == range ? theme.foreground : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            ConditionallyConcentricRectangle(cornerRadius: 8)
                                .fill(option == range ? theme.mutedBackground : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        sectionHeader(section.title)
                        ForEach(section.items) { item in
                            HistoryPanelRow(
                                item: item,
                                onOpen: { open(item, inNewTab: false) },
                                onOpenInNewTab: { open(item, inNewTab: true) },
                                onDelete: { delete(item) }
                            )
                            .onAppear { loadMoreIfNeeded(reaching: item) }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.mutedForeground)
            Text(searchText.isEmpty ? "No History" : "No results for \u{201C}\(searchText)\u{201D}")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if searchText.isEmpty {
                Text("Pages you visit in this space show up here")
                    .font(.system(size: 12))
                    .foregroundColor(theme.mutedForeground)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(AnimationSettings.easeOut(0.15)) {
                    sidebarManager.panel = .none
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Spaces")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.foreground.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .buttonStyle(.interactive(cornerRadius: 6))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // MARK: - Paging

    private func reload() {
        guard let containerId else {
            items = []
            hasMore = false
            return
        }
        let page = historyManager.page(
            matching: searchText,
            range: range,
            in: containerId,
            offset: 0,
            limit: Self.pageSize
        )
        items = page.items
        hasMore = page.hasMore
    }

    /// Infinite scroll: the fifth row from the end pulls the next page, so the list is
    /// already longer by the time the user reaches the bottom.
    private func loadMoreIfNeeded(reaching item: History) {
        guard hasMore, let containerId else { return }
        let triggerIndex = max(0, items.count - 5)
        guard let index = items.firstIndex(where: { $0.id == item.id }), index >= triggerIndex else { return }

        let page = historyManager.page(
            matching: searchText,
            range: range,
            in: containerId,
            offset: items.count,
            limit: Self.pageSize
        )
        // A row deleted between pages would otherwise shift the offset and duplicate one.
        let known = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { !known.contains($0.id) })
        hasMore = page.hasMore
    }

    // MARK: - Actions

    private func open(_ item: History, inNewTab: Bool) {
        let url = item.url
        if inNewTab || tabManager.activeTab == nil {
            tabManager.openTab(
                url: url,
                historyManager: historyManager,
                downloadManager: downloadManager,
                isPrivate: privacyMode.isPrivate
            )
        } else {
            tabManager.activeTab?.loadURL(url.absoluteString)
        }
    }

    private func delete(_ item: History) {
        let id = item.id
        historyManager.delete(item)
        withAnimation(AnimationSettings.easeOut(0.1)) {
            items.removeAll { $0.id == id }
        }
    }

    private func clearRange() {
        guard let containerId else { return }
        historyManager.delete(range: range, in: containerId)
        withAnimation(AnimationSettings.easeOut(0.1)) { reload() }
    }
}
