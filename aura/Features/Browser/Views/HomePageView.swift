import AppKit
import SwiftUI

/// `aura://home`, the new-tab page. Rendered natively inside the tab exactly like
/// `aura://settings`, so the search field is part of the page instead of a floating
/// overlay. Everything centres on this view's own geometry, which is the content pane:
/// the old window-wide launcher had to guess the pane and drifted off-centre.
struct HomePageView: View {
    /// The tab showing the page. `nil` when the space has no tabs at all, in which case
    /// submitting opens a tab rather than navigating this one.
    var tab: Tab?

    @Environment(\.theme) private var theme
    @Environment(TabManager.self) private var tabManager
    @Environment(AppState.self) private var appState
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @EnvironmentObject private var privacyMode: PrivacyMode

    @StateObject private var viewModel = LauncherViewModel()
    @State private var input = ""
    @State private var focusRequest = false
    @State private var mouseHasMoved = false
    @State private var mouseMonitor: Any?

    /// Distance from the top of the pane to the centre of the column.
    private static let verticalFraction: CGFloat = 0.38
    private static let fieldHeight: CGFloat = 44
    private static let fieldMaxWidth: CGFloat = 680
    /// Breathing room either side of the field at narrow pane widths.
    private static let horizontalInset: CGFloat = 48
    private static let cornerRadius: CGFloat = 12
    private static let tileSize: CGFloat = 40
    private static let maxShortcuts = 8

    var body: some View {
        GeometryReader { geo in
            let width = min(Self.fieldMaxWidth, max(geo.size.width - Self.horizontalInset, 220))
            column
                .frame(width: width)
                .position(x: geo.size.width / 2, y: geo.size.height * Self.verticalFraction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No visual-effect view here: the pane is translucent over the window blur that
        // `BrowserView` already draws, and an AppKit view spanning the page would shadow
        // the field and the tiles for hit testing.
        .background(theme.background.opacity(0.85))
        .environment(\.launcherMouseHasMoved, mouseHasMoved)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: tabManager.activeTab?.id) { _, id in
            if let tab, id == tab.id { focusField() }
        }
    }

    // MARK: - Column

    private var column: some View {
        VStack(spacing: 18) {
            Image("ora-logo-plain")
                .resizable()
                .renderingMode(.template)
                .frame(width: 64, height: 64)
                .foregroundColor(theme.foreground.opacity(0.25))

            Text("Less noise, more browsing.")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.foreground.opacity(0.35))

            searchField
                .frame(height: Self.fieldHeight)
                .overlay(alignment: .top) {
                    suggestions.offset(y: Self.fieldHeight + 8)
                }
                // The suggestions hang over the shortcut row rather than pushing it down,
                // so the field never moves while typing.
                .zIndex(1)

            shortcutsRow
        }
    }

    private var pill: some View {
        ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(theme.foreground.opacity(0.08))
            .overlay(
                ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(theme.foreground.opacity(0.06), lineWidth: 1)
            )
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: isValidURL(input) ? "globe" : "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(theme.foreground.opacity(0.55))
                .frame(width: 18, height: 18)

            LauncherTextField(
                text: $input,
                font: NSFont.systemFont(ofSize: 15, weight: .regular),
                onTab: {},
                onSubmit: { viewModel.executeCommand() },
                onDelete: { false },
                onMoveUp: { viewModel.moveFocusedElement(.up) },
                onMoveDown: { viewModel.moveFocusedElement(.down) },
                cursorColor: theme.foreground.opacity(0.8),
                textColor: theme.foreground,
                placeholder: "Search the web or enter URL...",
                // `true` asks for focus, `nil` leaves focus alone. A permanent `true`
                // would yank first responder back every time the view updated.
                isEditing: focusRequest ? true : nil
            )
            .onChange(of: input) { _, newValue in
                viewModel.currentText = newValue
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    viewModel.reset()
                } else {
                    viewModel.searchHandler(newValue)
                }
            }
        }
        .padding(.horizontal, 14)
        .background(pill)
    }

    @ViewBuilder
    private var suggestions: some View {
        if !viewModel.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.suggestions) { suggestion in
                    LauncherSuggestionItem(
                        suggestion: suggestion,
                        focusedElement: $viewModel.focusedElement
                    )
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.launcherMainBackground)
            .clipShape(ConditionallyConcentricRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                ConditionallyConcentricRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.foreground.opacity(0.05), lineWidth: 1)
                    .padding(0.25)
            )
            .shadow(color: .black.opacity(0.1), radius: 20, x: 0, y: 10)
        }
    }

    // MARK: - Shortcuts

    /// Favourites first, then pinned: the two sections the sidebar keeps above the
    /// scrolling tab list, which is what "shortcuts" means in this app.
    private var shortcuts: [Tab] {
        guard let container = tabManager.activeContainer else { return [] }
        return container.tabs
            .filter { $0.type == .fav || $0.type == .pinned }
            .sorted { lhs, rhs in
                lhs.type == rhs.type ? lhs.order < rhs.order : lhs.type == .fav
            }
            .prefix(Self.maxShortcuts)
            .map { $0 }
    }

    @ViewBuilder
    private var shortcutsRow: some View {
        let items = shortcuts
        if !items.isEmpty {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    Button { open(item) } label: {
                        FavIcon(
                            isWebViewReady: item.isWebViewReady,
                            favicon: item.favicon,
                            faviconLocalFile: item.faviconLocalFile,
                            textColor: theme.foreground.opacity(0.7)
                        )
                        .frame(width: Self.tileSize, height: Self.tileSize)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.foreground.opacity(0.06))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .accessibilityLabel(Text(item.title))
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Actions

    private func open(_ target: Tab) {
        if !target.isWebViewReady {
            target.restoreTransientState(
                historyManager: historyManager,
                downloadManager: downloadManager,
                tabManager: tabManager,
                isPrivate: privacyMode.isPrivate
            )
        }
        tabManager.activateTab(target)
    }

    /// Reached when nothing in the suggestion list was picked: plain search with the
    /// space's default engine.
    private func submit(_ newInput: String? = nil) {
        let query = newInput ?? input
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let engine = viewModel.searchEngineService.getDefaultSearchEngine(
            for: tabManager.activeContainer?.id
        ) else { return }
        let custom = viewModel.searchEngineService.settings.customSearchEngines
            .first { $0.searchURL == engine.searchURL }
        let match = engine.toLauncherMatch(originalAlias: query, customEngine: custom)
        guard let url = viewModel.searchEngineService.createSearchURL(for: match, query: query) else { return }

        input = ""
        viewModel.reset()
        if let tab {
            tab.loadURL(url.absoluteString)
        } else {
            tabManager.openTab(
                url: url,
                historyManager: historyManager,
                downloadManager: downloadManager,
                isPrivate: privacyMode.isPrivate
            )
        }
    }

    private func start() {
        viewModel.searchEngineService.setTheme(theme)
        viewModel.configure(
            tabManager: tabManager,
            historyManager: historyManager,
            downloadManager: downloadManager,
            appState: appState,
            privacyMode: privacyMode,
            onSubmit: submit,
            onDismiss: {},
            navigateInCurrentTab: tab != nil
        )
        focusField()
        mouseHasMoved = false
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                mouseHasMoved = true
                if let monitor = mouseMonitor {
                    NSEvent.removeMonitor(monitor)
                    mouseMonitor = nil
                }
                return event
            }
        }
    }

    private func stop() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        viewModel.reset()
        input = ""
        focusRequest = false
    }

    /// One-shot focus: raised for a beat so `LauncherTextField` picks it up, then dropped
    /// so a later click elsewhere on the page keeps first responder.
    private func focusField() {
        focusRequest = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusRequest = false
        }
    }
}
