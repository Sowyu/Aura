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
    @StateObject private var defaultBrowserManager = DefaultBrowserManager.shared
    @Bindable private var settings = SettingsStore.shared
    @State private var input = ""
    @State private var focusRequest = false
    @State private var mouseHasMoved = false
    @State private var mouseMonitor: Any?

    /// Distance from the top of the pane to the centre of the column.
    private static let verticalFraction: CGFloat = 0.38
    /// Same width and row height as the floating launcher, from the same constants.
    private static let fieldHeight = LauncherField.height
    private static let fieldMaxWidth = LauncherPlacement.width
    /// Breathing room either side of the field at narrow pane widths.
    private static let horizontalInset: CGFloat = 48
    private static let tileSize: CGFloat = 40
    private static let maxShortcuts = 8
    /// Gap between the suggestion panel's edge and its rows.
    private static let panelPadding: CGFloat = 6

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
                .foregroundColor(theme.foreground.opacity(0.6))

            searchField
                .frame(height: Self.fieldHeight)
                .overlay(alignment: .top) {
                    suggestions.offset(y: Self.fieldHeight + 8)
                }
                // The suggestions hang over the shortcut row rather than pushing it down,
                // so the field never moves while typing.
                .zIndex(1)

            shortcutsRow

            firstRunCard
        }
    }

    // MARK: - First run

    /// The one-time offer to make Aura the default browser and bring bookmarks over.
    ///
    /// Below the shortcuts rather than above the field: the search field is why the page
    /// exists, and a card that pushes it down on every new tab would be the first thing
    /// anyone asks to turn off. Dismissing writes a settings flag, so it is gone for
    /// good and not just for this window.
    @ViewBuilder
    private var firstRunCard: some View {
        if FirstRunCardPolicy.isVisible(
            isDefaultBrowser: defaultBrowserManager.isDefault,
            wasDismissed: settings.firstRunCardDismissed
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Make Aura your browser")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.foreground)
                        Text("Open links from other apps here, and bring the bookmarks you already have.")
                            .font(.system(size: 11))
                            .foregroundColor(theme.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        settings.firstRunCardDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.mutedForeground)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
                    .help("Do not show this again")
                    .accessibilityLabel(Text("Dismiss"))
                }

                HStack(spacing: 8) {
                    OraButton(label: "Set as Default", size: .sm) {
                        DefaultBrowserManager.requestSetAsDefault()
                        defaultBrowserManager.updateIsDefault()
                    }
                    OraButton(label: "Import Bookmarks\u{2026}", variant: .secondary, size: .sm) {
                        NotificationCenter.default.post(
                            name: .openSettingsTab,
                            object: nil,
                            userInfo: ["tab": SettingsTab.bookmarks.rawValue]
                        )
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                    .fill(theme.mutedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
            .padding(.top, 6)
        }
    }

    /// The exact row the ⌘T launcher draws, so the two never drift apart.
    private var searchField: some View {
        LauncherField(
            text: $input,
            onSubmit: { viewModel.executeCommand() },
            onMoveUp: { viewModel.moveFocusedElement(.up) },
            onMoveDown: { viewModel.moveFocusedElement(.down) },
            // Nothing to dismiss here, so Escape clears the query and its list.
            onEscape: {
                input = ""
                viewModel.reset()
            },
            placeholder: "Search or enter address",
            // `true` asks for focus, `nil` leaves focus alone. A permanent `true`
            // would yank first responder back every time the view updated.
            isEditing: focusRequest ? true : nil,
            onTextChange: { newValue in
                viewModel.currentText = newValue
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    viewModel.reset()
                } else {
                    viewModel.searchHandler(newValue)
                }
            }
        )
    }

    @ViewBuilder
    private var suggestions: some View {
        if !viewModel.suggestions.isEmpty {
            LauncherSuggestionsView(
                suggestions: $viewModel.suggestions,
                focusedElement: $viewModel.focusedElement,
                leadingInset: LauncherRowMetrics.leadingInset(
                    textInset: LauncherField.textInset,
                    panelPadding: Self.panelPadding,
                    iconWidth: LauncherField.iconWidth
                ),
                iconWidth: LauncherField.iconWidth
            )
            .padding(Self.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.launcherMainBackground)
            .clipShape(ConditionallyConcentricRectangle(
                cornerRadius: LauncherField.cornerRadius,
                style: .continuous
            ))
            .overlay(
                ConditionallyConcentricRectangle(
                    cornerRadius: LauncherField.cornerRadius,
                    style: .continuous
                )
                .stroke(theme.border, lineWidth: 1)
                .padding(0.25)
            )
            .auraFloatingShadow()
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
                            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                                .fill(theme.foreground.opacity(0.06))
                        )
                    }
                    .buttonStyle(.interactive(cornerRadius: AuraRadius.row, tint: theme.foreground))
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

/// When the home page shows its first-run card.
///
/// A named rule with no view attached, because the two inputs are the whole feature and
/// getting either backwards is invisible until someone reinstalls: a card that keeps
/// coming back after "no", or one that never appears at all.
enum FirstRunCardPolicy {
    static func isVisible(isDefaultBrowser: Bool, wasDismissed: Bool) -> Bool {
        !isDefaultBrowser && !wasDismissed
    }
}
