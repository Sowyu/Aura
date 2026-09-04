import AppKit
import SwiftUI

struct LauncherView: View {
    @Environment(AppState.self) private var appState
    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @EnvironmentObject var privacyMode: PrivacyMode
    @Environment(\.theme) private var theme
    @Environment(\.window) private var window

    @StateObject private var viewModel = LauncherViewModel()

    @State private var input = ""
    @State private var isVisible = false
    @FocusState private var isTextFieldFocused: Bool
    @State private var match: LauncherMatch?
    @State private var mouseHasMoved = false
    @State private var mouseMonitor: Any?
    /// The panel's own rect in window coordinates, so the click-away monitor can tell a
    /// click on the launcher from a click anywhere else.
    @State private var panelFrame: CGRect = .zero
    @State private var clickAwayMonitor: Any?

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
        // Clearing the field leaves the default suggestions up; Enter on them must not
        // open a search for an empty query.
        guard !correctInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appState.showLauncher = false
            return
        }
        var engineToUse = match

        if engineToUse == nil,
           let defaultEngine = viewModel.searchEngineService.getDefaultSearchEngine(
               for: tabManager.activeContainer?.id
           ) {
            let customEngine = viewModel.searchEngineService.settings.customSearchEngines
                .first { $0.searchURL == defaultEngine.searchURL }
            engineToUse = defaultEngine.toLauncherMatch(
                originalAlias: correctInput,
                customEngine: customEngine
            )
        }

        if let engine = engineToUse,
           let url = viewModel.searchEngineService.createSearchURL(for: engine, query: correctInput) {
            // Captured now: unmounting the panel clears the view's state, and the
            // environment objects outlive it.
            let tabManager = self.tabManager
            let historyManager = self.historyManager
            let downloadManager = self.downloadManager
            let isPrivate = privacyMode.isPrivate
            // Dismiss first and open one turn later, so the dismissal paints before
            // the tab's WKWebView is built. Built inline, the whole main-thread stall
            // showed as the launcher frozen on screen.
            appState.showLauncher = false
            DispatchQueue.main.async {
                tabManager.openTab(
                    url: url,
                    historyManager: historyManager,
                    downloadManager: downloadManager,
                    isPrivate: isPrivate
                )
            }
            return
        }
        appState.showLauncher = false
    }

    private func dismiss() {
        isVisible = false
        DispatchQueue.main.async {
            appState.showLauncher = false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let windowBounds = windowBounds(host: geo.frame(in: .global), fallback: geo.size)
            let width = LauncherPlacement.width(forWindowWidth: windowBounds.width)
            let origin = LauncherPlacement.origin(
                in: windowBounds,
                panelWidth: width,
                panelHeight: panelFrame.height > 0 ? panelFrame.height : LauncherField.height
            )
            ZStack(alignment: .topLeading) {
                backdrop
                    .frame(width: geo.size.width, height: geo.size.height)

                panel
                    .frame(width: width)
                    // Measured inside the offset, not outside it. A modifier applied after
                    // `.offset` is the offset's ancestor and is told the layout frame, which
                    // sits at this ZStack's top-left corner; only a descendant sees where
                    // the panel is drawn. Measured outside, the click-away test compared
                    // clicks against a rect in the corner, and a click on the panel closed
                    // the launcher whenever the two rects did not happen to overlap.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        panelFrame = $0
                    }
                    .offset(x: origin.x, y: origin.y)
                    // The panel re-centres on every measured height change, so every
                    // keystroke that adds or drops a row moves it. Animated, that reads as
                    // the field sliding under the cursor; it has to snap.
                    .animation(nil, value: origin.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.launcherMouseHasMoved, mouseHasMoved)
        .onExitCommand(perform: dismiss)
    }

    /// The window's content rect moved into this view's own coordinates. The overlay does
    /// not always start at the window's corner, so centring on `geo.size` alone would
    /// follow the chrome rather than the window; the geometry is only the fallback for
    /// the frame before the window is known.
    private func windowBounds(host: CGRect, fallback: CGSize) -> CGRect {
        guard let content = window?.contentView else {
            return CGRect(origin: .zero, size: fallback)
        }
        return CGRect(
            origin: CGPoint(x: -host.minX, y: -host.minY),
            size: content.bounds.size
        )
    }

    /// A click anywhere off the panel closes the launcher and stops there: it must not
    /// also pick a suggestion, focus the address bar or reach the page. The panel floats
    /// over a `WKWebView`, and an AppKit monitor is the only thing that sees the click
    /// before the web view does.
    private func startClickAway() {
        guard clickAwayMonitor == nil else { return }
        clickAwayMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            guard let eventWindow = event.window, window == nil || eventWindow === window else {
                return event
            }
            let height = eventWindow.contentView?.bounds.height ?? eventWindow.frame.height
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            // Unmeasured is not "outside": until the first geometry report lands, a click
            // is left alone rather than guessed at.
            guard panelFrame != .zero, !panelFrame.contains(point) else { return event }
            DispatchQueue.main.async { dismiss() }
            return nil
        }
    }

    private func stopClickAway() {
        if let clickAwayMonitor {
            NSEvent.removeMonitor(clickAwayMonitor)
        }
        clickAwayMonitor = nil
    }

    /// Blurs and dims the whole window behind the panel. `withinWindow` blending is what
    /// reaches the page: SwiftUI materials sit above the WKWebView's own layer and only
    /// tint it. It takes no clicks of its own; `startClickAway` handles those, and it
    /// covers the chrome and the traffic lights too, which no SwiftUI gesture reaches.
    private var backdrop: some View {
        ZStack {
            if SettingsStore.shared.launcherBlur {
                BlurEffectView(
                    material: .hudWindow,
                    blendingMode: .withinWindow,
                    isClickThrough: true
                )
            }
            Color.black.opacity(0.25)
        }
        .ignoresSafeArea()
        .opacity(isVisible ? 1 : 0)
        .animation(AnimationSettings.easeOut(0.12), value: isVisible)
        .allowsHitTesting(false)
    }

    private var panel: some View {
        LauncherMain(
            text: $input,
            match: $match,
            isFocused: $isTextFieldFocused,
            onTabPress: onTabPress,
            onEscape: dismiss,
            viewModel: viewModel
        )
        .opacity(isVisible ? 1.0 : 0.0)
        .animation(AnimationSettings.easeOut(0.12), value: isVisible)
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
            startClickAway()
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
            stopClickAway()
            panelFrame = .zero
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
