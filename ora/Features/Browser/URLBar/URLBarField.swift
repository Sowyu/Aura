import AppKit
import SwiftUI

/// Address field shared by the top toolbar and the floating URL bar.
/// Shows the current URL and morphs into the inline launcher while editing.
struct URLBarField: View {
    let tab: Tab
    /// Muted colour used for icons and secondary text.
    let foregroundColor: Color
    /// Full-strength colour used for typed text and the caret.
    let textColor: Color

    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var toolbarManager: ToolbarManager
    @EnvironmentObject var toastManager: ToastManager
    @EnvironmentObject var historyManager: HistoryManager
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var privacyMode: PrivacyMode

    @Environment(\.theme) private var theme

    @State private var showCopiedAnimation = false
    @State private var startWheelAnimation = false

    // Inline launcher state
    @StateObject private var launcherViewModel = LauncherViewModel()
    @State private var launcherInput = ""
    @FocusState private var isLauncherFocused: Bool
    @State private var mouseHasMoved = false
    @State private var mouseMonitor: Any?
    @State private var suppressInitialSearch = false

    private var isEditing: Bool {
        appState.isURLBarEditing
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isEditing {
                inlineLauncherInput
                    .transition(.blurReplace)
            } else {
                urlDisplayField
                    .transition(.blurReplace)
            }
        }
        .overlay(alignment: .top) {
            if isEditing {
                suggestionsOverlay()
                    .offset(y: 38)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: isEditing)
        // Hidden button for the focus-address-bar shortcut
        .overlay(
            Button("") { startEditing() }
                .oraShortcut(KeyboardShortcuts.Address.focus)
                .opacity(0)
                .allowsHitTesting(false)
        )
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

    // MARK: - URL Display Field (non-editing)

    private var urlDisplayField: some View {
        HStack(spacing: 8) {
            // Security indicator
            ZStack {
                if tab.isLoading {
                    ProgressView()
                        .tint(foregroundColor)
                        .scaleEffect(0.5)
                } else {
                    Image(systemName: tab.url.scheme == "https" ? "shield.lefthalf.filled" : "globe")
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

                // URL display
                let parts = URLDisplayUtils.displayParts(
                    url: tab.url,
                    title: tab.title,
                    showFull: toolbarManager.showFullURL
                )
                HStack(spacing: 0) {
                    Text(parts.host)
                        .font(.system(size: 14))
                        .foregroundColor(foregroundColor)
                    if let title = parts.title {
                        Text(" / \(title)")
                            .font(.system(size: 14))
                            .foregroundColor(foregroundColor.opacity(0.6))
                    }
                    Spacer()
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(showCopiedAnimation ? 0 : 1)
                .offset(y: showCopiedAnimation ? (startWheelAnimation ? -12 : 12) : 0)
                .animation(.easeOut(duration: 0.3), value: showCopiedAnimation)
                .animation(.easeOut(duration: 0.3), value: startWheelAnimation)
            }
            .font(.system(size: 14))
            .foregroundColor(foregroundColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Only the text area starts editing, so the copy button keeps its own hit area.
            // Mouse-down (not tap) so a drag selects text instead of moving the window.
            .overlay(MouseDownCatcher { startEditing() })

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
            .oraShortcutHelp("Copy URL", for: KeyboardShortcuts.Address.copyURL)
            .accessibilityLabel(Text("Copy URL"))
        }
        .frame(height: 30)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .background(
            ConditionallyConcentricRectangle(cornerRadius: 10, style: .continuous)
                .fill(foregroundColor.opacity(0.08))
        )
    }

    // MARK: - Inline Launcher Input (editing)

    private var inlineLauncherInput: some View {
        HStack(spacing: 8) {
            Image(systemName: isValidURL(launcherInput) ? "globe" : "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(foregroundColor)
                .frame(width: 16, height: 16)

            LauncherTextField(
                text: $launcherInput,
                font: NSFont.systemFont(ofSize: 14, weight: .regular),
                onTab: {},
                onSubmit: {
                    launcherViewModel.executeCommand()
                },
                onDelete: { false },
                onMoveUp: {
                    launcherViewModel.moveFocusedElement(.up)
                },
                onMoveDown: {
                    launcherViewModel.moveFocusedElement(.down)
                },
                cursorColor: textColor.opacity(0.8),
                textColor: textColor.opacity(0.7),
                placeholder: "Search the web or enter URL..."
            )
            .textFieldStyle(PlainTextFieldStyle())
            .focused($isLauncherFocused)
            .onChange(of: launcherInput) { _, newValue in
                launcherViewModel.currentText = newValue
                guard !suppressInitialSearch else { return }
                launcherViewModel.searchHandler(newValue)
            }
            .onKeyPress(.escape) {
                dismissEditing()
                return .handled
            }
        }
        .onAppear {
            setupInlineLauncher()
        }
        .onDisappear {
            cleanupInlineLauncher()
        }
        .frame(height: 30)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ConditionallyConcentricRectangle(cornerRadius: 10, style: .continuous)
                .fill(foregroundColor.opacity(0.08))
                .overlay(
                    ConditionallyConcentricRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            foregroundColor.opacity(0.1),
                            lineWidth: 1.2
                        )
                )
        )
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
    private func startEditing() {
        guard !isEditing else { return }
        // Pre-fill input before animation so the text field isn't empty on appear
        if let activeTab = tabManager.activeTab {
            launcherInput = activeTab.url.absoluteString
        }
        withAnimation(.easeOut(duration: 0.1)) {
            appState.isURLBarEditing = true
        }
    }

    private func setupInlineLauncher() {
        suppressInitialSearch = true
        if launcherInput.isEmpty, let activeTab = tabManager.activeTab {
            launcherInput = activeTab.url.absoluteString
        }
        launcherViewModel.searchEngineService.setTheme(theme)
        launcherViewModel.configure(
            tabManager: tabManager,
            historyManager: historyManager,
            downloadManager: downloadManager,
            appState: appState,
            privacyMode: privacyMode,
            onSubmit: onLauncherSubmit,
            onDismiss: dismissEditing,
            navigateInCurrentTab: true
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isLauncherFocused = true
        }
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
            isLauncherFocused = false
            mouseHasMoved = false
            suppressInitialSearch = false
            launcherInput = ""
            launcherViewModel.reset()
        }
    }

    private func dismissEditing() {
        DispatchQueue.main.async {
            guard appState.isURLBarEditing else { return }
            withAnimation(.easeOut(duration: 0.2)) {
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
                tabManager.activeTab?.loadURL(url.absoluteString)
            }
        }
        dismissEditing()
    }
}
