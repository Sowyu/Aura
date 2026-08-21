import AppKit
import SwiftUI

/// Address field shared by the top toolbar and the floating URL bar.
/// Shows the current URL and morphs into the inline launcher while editing.
struct URLBarField: View {
    /// `nil` while no tab is active; the field still renders as an empty pill.
    let tab: Tab?
    /// Muted colour used for icons and secondary text.
    let foregroundColor: Color
    /// Full-strength colour used for typed text and the caret. Also drives the
    /// pill fill, so callers must pass an undimmed colour.
    let textColor: Color

    @Environment(TabManager.self) private var tabManager
    @Environment(AppState.self) private var appState
    @Environment(ToolbarManager.self) private var toolbarManager
    @Environment(ToastManager.self) private var toastManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @EnvironmentObject var privacyMode: PrivacyMode

    @Environment(\.theme) private var theme

    @State private var showCopiedAnimation = false
    @State private var startWheelAnimation = false

    // Inline launcher state
    @StateObject private var launcherViewModel = LauncherViewModel()
    @State private var launcherInput = ""
    @State private var mouseHasMoved = false
    @State private var mouseMonitor: Any?
    @State private var suppressInitialSearch = false

    private var isEditing: Bool {
        appState.isURLBarEditing
    }

    /// The active space's colour, or nil while it is on Auto.
    private var spaceTint: Color? {
        guard let hex = tabManager.activeContainer?.iconColorHex, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    /// One pill for both modes so entering edit mode cannot change the height. A space
    /// with a colour rings the field in it, which is the address bar's half of the
    /// container cue the sidebar rows carry as a stripe.
    private var pill: some View {
        ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(textColor.opacity(0.08))
            .overlay(
                ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(textColor.opacity(0.06), lineWidth: 1)
            )
            .overlay {
                if let spaceTint {
                    ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius - 1.5, style: .continuous)
                        .stroke(spaceTint.opacity(0.85), lineWidth: 3)
                        .padding(1.5)
                }
            }
    }

    static let height: CGFloat = 30
    private static let cornerRadius: CGFloat = 10

    // MARK: - Body

    var body: some View {
        field
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { appState.urlFieldFrame = $0 }
        .overlay(alignment: .top) {
            if isEditing {
                suggestionsOverlay()
                    .offset(y: 38)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        appState.urlSuggestionsFrame = $0
                    }
                    .onDisappear { appState.urlSuggestionsFrame = .zero }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isEditing)
        // Hidden button for the focus-address-bar shortcut
        .overlay(
            Button("") { startEditing() }
                .oraShortcut(KeyboardShortcuts.Address.focus)
                .opacity(0)
                .allowsHitTesting(false)
        )
        .onChange(of: isEditing) { _, editing in
            if editing {
                setupInlineLauncher()
            } else {
                cleanupInlineLauncher()
            }
        }
        .onChange(of: tabManager.activeTab?.id) { _, _ in
            if isEditing {
                dismissEditing()
            }
        }
        .onChange(of: appState.showLauncher) { _, newValue in
            // Dismiss URL bar editing if the center launcher is opened
            if newValue, isEditing {
                dismissEditing()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .copyAddressURL)) { _ in
            if let activeTab = tabManager.activeTab {
                ClipboardUtils.copyWithToast(
                    activeTab.url.absoluteString,
                    toastManager: toastManager
                )
            }
        }
    }

    // MARK: - Field

    /// One NSTextField for both modes. The field editor owns mouse tracking, so a
    /// drag selects text instead of moving the hidden-titlebar window.
    private var field: some View {
        HStack(spacing: 8) {
            ZStack {
                if tab?.isLoading == true, !isEditing {
                    ProgressView()
                        .tint(foregroundColor)
                        .scaleEffect(0.5)
                } else {
                    Image(systemName: isEditing ? editingSymbol : securitySymbol)
                        .font(.system(size: 12))
                        .foregroundColor(foregroundColor)
                }
            }
            .frame(width: 16, height: 16)

            ZStack(alignment: .leading) {
                CopiedURLOverlay(
                    foregroundColor: foregroundColor,
                    showCopiedAnimation: $showCopiedAnimation,
                    startWheelAnimation: $startWheelAnimation
                )

                LauncherTextField(
                    text: $launcherInput,
                    font: NSFont.systemFont(ofSize: 14, weight: .regular),
                    onTab: {},
                    onSubmit: { launcherViewModel.executeCommand() },
                    onDelete: { false },
                    onMoveUp: { launcherViewModel.moveFocusedElement(.up) },
                    onMoveDown: { launcherViewModel.moveFocusedElement(.down) },
                    cursorColor: textColor.opacity(0.8),
                    textColor: isEditing ? textColor.opacity(0.7) : foregroundColor,
                    placeholder: isEditing ? "Search the web or enter URL..." : "Search or enter address",
                    displayText: displayText,
                    isEditing: isEditing,
                    onBeginEditing: startEditing,
                    onEndEditing: dismissEditing,
                    onEscape: dismissEditing
                )

                // Single line: let the HStack centre it instead of filling the pill and drawing at the top.

                .fixedSize(horizontal: false, vertical: true)
                .opacity(showCopiedAnimation ? 0 : 1)
                .offset(y: showCopiedAnimation ? (startWheelAnimation ? -12 : 12) : 0)
                .animation(.easeOut(duration: 0.15), value: showCopiedAnimation)
                .animation(.easeOut(duration: 0.15), value: startWheelAnimation)
                .onChange(of: launcherInput) { _, newValue in
                    guard isEditing else { return }
                    launcherViewModel.currentText = newValue
                    guard !suppressInitialSearch else { return }
                    launcherViewModel.searchHandler(newValue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if let activeTab = tabManager.activeTab {
                    ClipboardUtils.triggerCopy(
                        activeTab.url.absoluteString,
                        showCopiedAnimation: $showCopiedAnimation,
                        startWheelAnimation: $startWheelAnimation
                    )
                }
            } label: {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(foregroundColor)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.interactive(cornerRadius: 6, tint: foregroundColor))
            .disabled(tab == nil || isEditing)
            .opacity(tab == nil || isEditing ? 0 : 1)
            .oraShortcutHelp("Copy URL", for: KeyboardShortcuts.Address.copyURL)
            .accessibilityLabel(Text("Copy URL"))
        }
        .frame(height: Self.height)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .background(pill)
    }

    private var securitySymbol: String {
        guard let tab else { return "magnifyingglass" }
        return tab.url.scheme == "https" ? "shield.lefthalf.filled" : "globe"
    }

    private var editingSymbol: String {
        isValidURL(launcherInput) ? "globe" : "magnifyingglass"
    }

    private var displayText: String {
        guard let tab else { return "" }
        return URLDisplayUtils.displayString(url: tab.url, title: tab.title, showFull: toolbarManager.showFullURL)
    }

    // MARK: - Suggestions Overlay

    @ViewBuilder
    private func suggestionsOverlay() -> some View {
        if !launcherViewModel.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(launcherViewModel.suggestions) { suggestion in
                    LauncherSuggestionItem(
                        suggestion: suggestion,
                        focusedElement: $launcherViewModel.focusedElement
                    )
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.launcherMainBackground)
            .background(BlurEffectView(material: .popover, blendingMode: .withinWindow))
            .clipShape(ConditionallyConcentricRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                ConditionallyConcentricRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.foreground.opacity(0.05), lineWidth: 1)
                    .padding(0.25)
            )
            .shadow(color: .black.opacity(0.1), radius: 20, x: 0, y: 10)
            .environment(\.launcherMouseHasMoved, mouseHasMoved)
        }
    }
}

// MARK: - Inline launcher

extension URLBarField {
    /// Called from the shortcut and from the text field becoming first responder.
    private func startEditing() {
        guard !isEditing else { return }
        // Pre-fill before flipping the flag so the field edits the URL, not the host.
        suppressInitialSearch = true
        launcherInput = tabManager.activeTab?.url.absoluteString ?? ""
        withAnimation(.easeOut(duration: 0.1)) {
            appState.isURLBarEditing = true
        }
    }

    private func setupInlineLauncher() {
        suppressInitialSearch = true
        launcherViewModel.searchEngineService.setTheme(theme)
        launcherViewModel.configure(
            tabManager: tabManager,
            historyManager: historyManager,
            downloadManager: downloadManager,
            appState: appState,
            privacyMode: privacyMode,
            onSubmit: onLauncherSubmit,
            onDismiss: dismissEditing,
            navigateInCurrentTab: tabManager.activeTab != nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            suppressInitialSearch = false
        }

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

    private func cleanupInlineLauncher() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        DispatchQueue.main.async {
            guard !appState.isURLBarEditing else { return }
            mouseHasMoved = false
            suppressInitialSearch = false
            launcherInput = ""
            launcherViewModel.reset()
        }
    }

    private func dismissEditing() {
        DispatchQueue.main.async {
            guard appState.isURLBarEditing else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                appState.isURLBarEditing = false
            }
        }
    }

    private func onLauncherSubmit(_ newInput: String? = nil) {
        let correctInput = newInput ?? launcherInput

        if let defaultEngine = launcherViewModel.searchEngineService.getDefaultSearchEngine(
            for: tabManager.activeContainer?.id
        ) {
            let customEngine = launcherViewModel.searchEngineService.settings.customSearchEngines
                .first { $0.searchURL == defaultEngine.searchURL }
            let match = defaultEngine.toLauncherMatch(
                originalAlias: correctInput,
                customEngine: customEngine
            )
            if let url = launcherViewModel.searchEngineService.createSearchURL(for: match, query: correctInput) {
                if let activeTab = tabManager.activeTab {
                    activeTab.loadURL(url.absoluteString)
                } else {
                    // No tab to navigate: the field is still usable, so open one.
                    tabManager.openTab(
                        url: url,
                        historyManager: historyManager,
                        downloadManager: downloadManager,
                        isPrivate: privacyMode.isPrivate
                    )
                }
            }
        }
        dismissEditing()
    }
}
