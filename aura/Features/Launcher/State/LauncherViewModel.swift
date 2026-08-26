import SwiftUI

@MainActor
class LauncherViewModel: ObservableObject {
    let searchEngineService = SearchEngineService()

    @Published var suggestions: [LauncherSuggestion] = []
    @Published var focusedElement: UUID = .init()

    /// Kept in sync with the view's text binding so closures can read current input.
    var currentText: String = ""

    private let debouncer = Debouncer(delay: 0.2)
    private var autoSuggestionRequestID = 0
    /// How long a burst of typing coalesces into one local search.
    static let localSearchDebounce: TimeInterval = 0.04
    private var localSearchTask: Task<Void, Never>?
    private var lastLocalSearchAt: Date?

    // Dependencies injected from the view layer
    private(set) var tabManager: TabManager?
    private(set) var historyManager: HistoryManager?
    private(set) var downloadManager: DownloadManager?
    private(set) var appState: AppState?
    private(set) var privacyMode: PrivacyMode?
    private(set) var onSubmit: ((String?) -> Void)?
    private(set) var onDismiss: (() -> Void)?
    var navigateInCurrentTab: Bool = false

    func configure(
        tabManager: TabManager,
        historyManager: HistoryManager,
        downloadManager: DownloadManager,
        appState: AppState,
        privacyMode: PrivacyMode,
        onSubmit: @escaping (String?) -> Void,
        onDismiss: (() -> Void)? = nil,
        navigateInCurrentTab: Bool = false
    ) {
        self.tabManager = tabManager
        self.historyManager = historyManager
        self.downloadManager = downloadManager
        self.appState = appState
        self.privacyMode = privacyMode
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        self.navigateInCurrentTab = navigateInCurrentTab
    }

    // MARK: - Search Logic

    /// Rows are merged and ranked by `LauncherResultMerger` (ported from Beam), with one
    /// exception it enforces itself: row 0 is always what the typed text does. An open tab
    /// that happens to match the address is a row you can arrow onto, never the default.
    func searchHandler(_ text: String) {
        guard tabManager != nil, historyManager != nil else { return }

        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            invalidateAutoSuggestionRequests()
            suggestions = defaultSuggestions()
            focusedElement = suggestions.first?.id ?? UUID()
            return
        }

        let requestID = nextAutoSuggestionRequestID()

        // The history fetch and the tab scan used to run on every keystroke, on the main
        // thread, between the key going down and the character appearing.
        localSearchTask?.cancel()
        let now = Date()
        if Self.runsLocalSearchNow(lastRunAt: lastLocalSearchAt, now: now) {
            lastLocalSearchAt = now
            runLocalSearch(text)
        } else {
            localSearchTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.localSearchDebounce))
                guard !Task.isCancelled, let self else { return }
                self.lastLocalSearchAt = Date()
                self.runLocalSearch(text)
            }
        }

        // Not for a palette query: a search engine has nothing to say about `>reload`,
        // and its answers would land in the middle of the command list.
        if AppCommandCatalog.paletteQuery(text) == nil {
            requestAutoSuggestions(text, requestID: requestID)
        }
    }

    /// The first keystroke after a pause searches immediately, so the list is there for
    /// the first character typed. Anything closer than the window waits it out, which is
    /// what keeps a held-down key from running one history fetch per repeat.
    static func runsLocalSearchNow(
        lastRunAt: Date?,
        now: Date,
        window: TimeInterval = LauncherViewModel.localSearchDebounce
    ) -> Bool {
        guard let lastRunAt else { return true }
        return now.timeIntervalSince(lastRunAt) >= window
    }

    private func runLocalSearch(_ text: String) {
        guard let tabManager, let historyManager else { return }

        // `>` hands the whole list to the app's commands: there is no address in a
        // palette query, so nothing else belongs in it.
        if let palette = AppCommandCatalog.paletteQuery(text) {
            suggestions = commandSuggestions(palette, palette: true)
            focusedElement = suggestions.first?.id ?? UUID()
            return
        }

        let histories = historyManager.search(
            text,
            activeContainerId: tabManager.activeContainer?.id ?? UUID()
        )
        let tabs = tabManager.search(text)

        suggestions = LauncherResultMerger.merge(
            typed: typedTextSuggestion(text),
            links: historySuggestions(histories, matching: text) + commandSuggestions(text, palette: false),
            openTabs: openTabSuggestions(tabs, matching: text),
            trailing: trailingSuggestions(text)
        )
        focusedElement = suggestions.first?.id ?? UUID()
    }

    /// Rows for the app's own commands. See `AppCommand.swift` for the row itself.
    private func commandSuggestions(_ query: String, palette: Bool) -> [LauncherSuggestion] {
        AppCommandCatalog.matches(query, palette: palette).map {
            LauncherSuggestion(command: $0, query: query, palette: palette)
        }
    }

    func reset() {
        invalidateAutoSuggestionRequests()
        localSearchTask?.cancel()
        lastLocalSearchAt = nil
        suggestions = []
        focusedElement = UUID()
        currentText = ""
    }

    func defaultSuggestions() -> [LauncherSuggestion] {
        guard let tabManager else { return [] }
        let containerId = tabManager.activeContainer?.id
        let searchEngine = searchEngineService.getDefaultSearchEngine(for: containerId)
        let engineName = searchEngine?.name ?? "Google"
        return [
            LauncherSuggestion(
                type: .suggestedQuery, title: "Search on \(engineName)",
                action: { [weak self] in self?.onSubmit?(nil) }
            ),
            createAISuggestion(engineName: .grok),
            createAISuggestion(engineName: .chatgpt),
            createAISuggestion(engineName: .claude),
            createAISuggestion(engineName: .gemini)
        ]
    }

    /// Enter runs the focused row. With no usable row it falls back to the typed text:
    /// the URL bar accepts typing for 150 ms before the first `searchHandler` runs, and
    /// Enter in that window used to do nothing at all.
    func executeCommand() {
        if let suggestion = suggestions.first(where: { $0.id == focusedElement }) {
            suggestion.action()
        } else {
            submitPrimary()
        }
        onDismiss?()
    }

    /// Runs the typed text through the caller's submit path, skipping the suggestion list.
    /// Used when a search-engine capsule is showing and the list is hidden.
    func submitTypedText() {
        onSubmit?(nil)
    }

    /// What row 0 would do: navigate when the text is an address, search it otherwise.
    func submitPrimary() {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedTextSuggestion(text)?.action()
    }

    func moveFocusedElement(_ dir: MoveDirection) {
        guard !suggestions.isEmpty else { return }
        guard let idx = suggestions.firstIndex(where: { $0.id == focusedElement }) else {
            // Focus was left on a row that no longer exists (the list arrived after a
            // reset). Without this the arrow keys stayed dead until the next keystroke.
            focusedElement = suggestions[0].id
            return
        }
        let offset = dir == .up ? -1 : 1
        let newIndex = (idx + offset + suggestions.count) % suggestions.count
        focusedElement = suggestions[newIndex].id
    }

    // MARK: - Private Helpers

    private func createAISuggestion(engineName: SearchEngineID, query: String? = nil)
        -> LauncherSuggestion {
        guard let engine = searchEngineService.getSearchEngine(engineName) else {
            return LauncherSuggestion(
                type: .aiChat,
                title: query ?? engineName.rawValue,
                name: engineName.rawValue,
                action: {}
            )
        }

        return LauncherSuggestion(
            type: .aiChat,
            title: query ?? engine.name,
            name: engine.name,
            icon: engine.icon.isEmpty ? nil : engine.icon,
            color: engine.color,
            engineForegroundColor: engine.foregroundColor,
            action: { [weak self] in
                guard let self, let tabManager = self.tabManager,
                      let historyManager = self.historyManager,
                      let privacyMode = self.privacyMode
                else { return }
                if self.navigateInCurrentTab, let tab = tabManager.activeTab {
                    if let url = self.searchEngineService.getSearchURLForEngine(
                        engineName: engineName,
                        query: query ?? self.currentText
                    ) {
                        tab.loadURL(url.absoluteString)
                    }
                } else {
                    // Resolved now: `reset()` clears `currentText` when the panel
                    // unmounts, before the deferred open runs.
                    let resolvedQuery = query ?? self.currentText
                    let isPrivate = privacyMode.isPrivate
                    DispatchQueue.main.async {
                        tabManager.openFromEngine(
                            engineName: engineName,
                            query: resolvedQuery,
                            historyManager: historyManager,
                            isPrivate: isPrivate
                        )
                    }
                }
            }
        )
    }

    private func openTabSuggestions(_ tabs: [Tab], matching text: String) -> [LauncherSuggestion] {
        guard let tabManager, let historyManager, let downloadManager, let privacyMode else {
            return []
        }
        return tabs.prefix(6).enumerated().map { rank, tab in
            LauncherSuggestion(
                type: .openedTab,
                title: tab.title,
                url: tab.url,
                faviconURL: tab.favicon,
                faviconLocalFile: tab.faviconLocalFile,
                score: 1 - Float(rank) * 0.01,
                completingText: text,
                action: {
                    let isPrivate = privacyMode.isPrivate
                    // One turn later: rebuilding a hibernated tab's web view blocks
                    // the main thread, and the launcher should be gone first.
                    DispatchQueue.main.async {
                        if !tab.isWebViewReady {
                            tab.restoreTransientState(
                                historyManager: historyManager,
                                downloadManager: downloadManager,
                                tabManager: tabManager,
                                isPrivate: isPrivate
                            )
                        }
                        tabManager.activateTab(tab)
                    }
                }
            )
        }
    }

    /// The typed text as a row: an address to open, or a search for it. Always row 0.
    private func typedTextSuggestion(_ text: String) -> LauncherSuggestion? {
        typedURLSuggestion(text) ?? searchSuggestion(text)
    }

    private func typedURL(_ text: String) -> URL? {
        if let candidate = URL(string: text), candidate.scheme != nil, candidate.host != nil {
            return candidate
        }
        return isValidURL(text) ? constructURL(from: text) : nil
    }

    private func typedURLSuggestion(_ text: String) -> LauncherSuggestion? {
        guard let tabManager, let historyManager, let privacyMode else { return nil }
        guard let url = typedURL(text) else { return nil }
        let navigateCurrent = navigateInCurrentTab
        return LauncherSuggestion(
            type: .suggestedLink,
            title: text,
            url: url,
            completingText: text,
            action: {
                if navigateCurrent {
                    tabManager.activeTab?.loadURL(url.absoluteString)
                } else {
                    let isPrivate = privacyMode.isPrivate
                    // One turn later, so the launcher's dismissal paints before the
                    // new tab's web view blocks the main thread.
                    DispatchQueue.main.async {
                        tabManager.openTab(
                            url: url,
                            historyManager: historyManager,
                            isPrivate: isPrivate
                        )
                    }
                }
            }
        )
    }

    private func searchSuggestion(_ text: String) -> LauncherSuggestion? {
        guard let tabManager else { return nil }
        let containerId = tabManager.activeContainer?.id
        let searchEngine = searchEngineService.getDefaultSearchEngine(for: containerId)
        let engineName = searchEngine?.name ?? "Google"
        return LauncherSuggestion(
            type: .suggestedQuery,
            title: "\(text) - \(engineName)",
            action: { [weak self] in self?.onSubmit?(nil) }
        )
    }

    /// Rows that stay at the bottom: the plain search when row 0 took the address, then
    /// the AI engines when the text reads like a question.
    private func trailingSuggestions(_ text: String) -> [LauncherSuggestion] {
        var trailing: [LauncherSuggestion] = []
        if typedURL(text) != nil, let search = searchSuggestion(text) {
            trailing.append(search)
        }
        trailing.append(contentsOf: aiSuggestions(for: text))
        return trailing
    }

    private func requestAutoSuggestions(_ text: String, requestID: Int) {
        guard let tabManager else { return }
        let containerId = tabManager.activeContainer?.id
        debouncer.run { [weak self] in
            guard let self else { return }
            let isCurrentRequest = await MainActor.run {
                requestID == self.autoSuggestionRequestID && self.currentText == text
            }
            guard isCurrentRequest else { return }

            let searchEngine = await self.searchEngineService.getDefaultSearchEngine(
                for: containerId
            )
            guard let autoSuggestions = searchEngine?.autoSuggestions else { return }
            let searchSuggestions = await autoSuggestions(text)
            await MainActor.run {
                guard requestID == self.autoSuggestionRequestID, self.currentText == text else {
                    return
                }
                let rows = searchSuggestions.map { title in
                    LauncherSuggestion(
                        type: .suggestedQuery,
                        title: title,
                        completingText: text,
                        action: { [weak self] in self?.onSubmit?(title) }
                    )
                }
                self.suggestions = LauncherResultMerger.insertSearchResults(
                    rows,
                    into: self.suggestions,
                    focused: self.focusedElement
                )
            }
        }
    }

    private func nextAutoSuggestionRequestID() -> Int {
        autoSuggestionRequestID += 1
        debouncer.cancel()
        return autoSuggestionRequestID
    }

    private func invalidateAutoSuggestionRequests() {
        autoSuggestionRequestID += 1
        debouncer.cancel()
    }

    private func historySuggestions(_ histories: [History], matching text: String) -> [LauncherSuggestion] {
        guard let tabManager, let historyManager, let privacyMode else { return [] }
        let navigateCurrent = navigateInCurrentTab
        return histories.prefix(6).enumerated().map { rank, history in
            LauncherSuggestion(
                type: .suggestedLink,
                title: history.title,
                url: history.url,
                faviconURL: history.faviconURL,
                faviconLocalFile: history.faviconLocalFile,
                // Frecency stand-in: visits lift the row, and the fetch already came back
                // most recent first, so the position only breaks ties.
                score: 1 + log2(1 + Float(min(history.visitCount, 50))) * 0.05 - Float(rank) * 0.01,
                completingText: text,
                action: {
                    if navigateCurrent {
                        tabManager.activeTab?.loadURL(history.url.absoluteString)
                    } else {
                        let isPrivate = privacyMode.isPrivate
                        // One turn later, so the dismissal paints before the web
                        // view build stalls the main thread.
                        DispatchQueue.main.async {
                            tabManager.openTab(
                                url: history.url,
                                historyManager: historyManager,
                                isPrivate: isPrivate
                            )
                        }
                    }
                }
            )
        }
    }

    private func aiSuggestions(for text: String) -> [LauncherSuggestion] {
        guard isAISuitableQuery(text) else { return [] }
        return [
            createAISuggestion(engineName: .grok, query: text),
            createAISuggestion(engineName: .chatgpt, query: text),
            createAISuggestion(engineName: .claude, query: text),
            createAISuggestion(engineName: .gemini, query: text)
        ]
    }

    private func isAISuitableQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let words = lowercased.split(separator: " ")

        // Negative signals: single words and URLs are not AI queries
        if words.count <= 1 { return false }
        if isValidURL(trimmed) { return false }

        // Starts with a question word
        let questionPrefixes = [
            "who ", "what ", "where ", "when ", "how ", "why ", "which ",
            "is ", "are ", "can ", "does ", "do ", "should ", "would ",
            "could ", "will ", "was ", "were ", "has ", "have "
        ]
        if questionPrefixes.contains(where: { lowercased.hasPrefix($0) }) {
            return true
        }

        // Ends with a question mark
        if trimmed.hasSuffix("?") {
            return true
        }

        // Imperative / command phrases
        let imperativePhrases = [
            "write me", "help me", "create a", "give me", "list of",
            "make a", "tell me", "show me", "find me", "build a",
            "design a", "plan a", "write a", "make me", "help with"
        ]
        if imperativePhrases.contains(where: { lowercased.contains($0) }) {
            return true
        }

        // Action keywords
        let actionKeywords = [
            "summarize", "rewrite", "explain", "generate", "how to",
            "translate", "compare", "alternatives", "improve", "suggest",
            "recommend", "analyze", "convert", "calculate", "define",
            "describe", "simplify", "debug", "optimize", "refactor",
            "review", "draft", "code", "idea", "opinion", "story",
            "joke", "email"
        ]
        if actionKeywords.contains(where: { lowercased.contains($0) }) {
            return true
        }

        // Natural language heuristic: 4+ words likely conversational
        if words.count >= 4 {
            return true
        }

        return false
    }
}

private class Debouncer {
    private var workItem: DispatchWorkItem?
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func run(_ block: @escaping @Sendable () async -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem {
            Task { await block() }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
