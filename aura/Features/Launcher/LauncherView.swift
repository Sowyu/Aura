import AppKit
import SwiftUI

struct LauncherView: View {
    @Environment(AppState.self) private var appState
    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @EnvironmentObject var privacyMode: PrivacyMode
    @Environment(\.theme) private var theme

    @StateObject private var viewModel = LauncherViewModel()

    @State private var input = ""
    @State private var isVisible = false
    @FocusState private var isTextFieldFocused: Bool
    @State private var match: LauncherMatch?
    @State private var mouseHasMoved = false
    @State private var mouseMonitor: Any?

    private func onTabPress() {
        guard !input.isEmpty else { return }
        if let searchEngine = viewModel.searchEngineService.findSearchEngine(for: input) {
            let customEngine = viewModel.searchEngineService.settings.customSearchEngines
                .first { $0.searchURL == searchEngine.searchURL }
            match = searchEngine.toLauncherMatch(
                originalAlias: input,
                customEngine: customEngine
            )
            input = ""
        }
    }

    private func onSubmit(_ newInput: String? = nil) {
        let correctInput = newInput ?? input
        var engineToUse = match

        if engineToUse == nil,
           let defaultEngine = viewModel.searchEngineService.getDefaultSearchEngine(
               for: tabManager.activeContainer?.id
           )
        {
            let customEngine = viewModel.searchEngineService.settings.customSearchEngines
                .first { $0.searchURL == defaultEngine.searchURL }
            engineToUse = defaultEngine.toLauncherMatch(
                originalAlias: correctInput,
                customEngine: customEngine
            )
        }

        if let engine = engineToUse,
           let url = viewModel.searchEngineService.createSearchURL(for: engine, query: correctInput)
        {
            tabManager
                .openTab(
                    url: url,
                    historyManager: historyManager,
                    downloadManager: downloadManager,
                    isPrivate: privacyMode.isPrivate
                )
        }
        appState.showLauncher = false
    }

    private func dismiss() {
        guard tabManager.activeTab != nil else { return }
        isVisible = false
        DispatchQueue.main.async {
            appState.showLauncher = false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let window = CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                backdrop
                    .frame(width: geo.size.width, height: geo.size.height)

                panel
                    .frame(width: LauncherPlacement.width(forWindowWidth: geo.size.width))
                    .position(LauncherPlacement.position(in: window))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.launcherMouseHasMoved, mouseHasMoved)
        .onExitCommand(perform: dismiss)
    }

    /// Blurs and dims the whole window behind the panel. `withinWindow` blending is what
    /// reaches the page: SwiftUI materials sit above the WKWebView's own layer and only
    /// tint it. The view is mounted solely while the launcher is open and never hit-tests,
    /// so the dim below it is what takes the dismissing click.
    private var backdrop: some View {
        ZStack {
            BlurEffectView(
                material: .hudWindow,
                blendingMode: .withinWindow,
                isClickThrough: true
            )
            Color.black.opacity(0.25)
        }
        .ignoresSafeArea()
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isVisible)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
    }

    private var panel: some View {
        LauncherMain(
            text: $input,
            match: $match,
            isFocused: $isTextFieldFocused,
            onTabPress: onTabPress,
            viewModel: viewModel
        )
        .gradientAnimatingBorder(
            color: match?.color ?? .clear,
            trigger: match != nil
        )
        .opacity(isVisible ? 1.0 : 0.0)
        .animation(.easeOut(duration: 0.12), value: isVisible)
        .onAppear {
            isVisible = true
            isTextFieldFocused = true
            if !appState.launcherSearchText.isEmpty {
                input = appState.launcherSearchText
                appState.launcherSearchText = ""
            }
            viewModel.searchEngineService.setTheme(theme)
            viewModel.configure(
                tabManager: tabManager,
                historyManager: historyManager,
                downloadManager: downloadManager,
                appState: appState,
                privacyMode: privacyMode,
                onSubmit: onSubmit,
                onDismiss: { [weak appState] in
                    appState?.showLauncher = false
                }
            )
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
        .onDisappear {
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
                mouseMonitor = nil
            }
            viewModel.reset()
            input = ""
            match = nil
            isTextFieldFocused = false
        }
        .onChange(of: appState.showLauncher) { _, newValue in
            isVisible = newValue
        }
    }
}
