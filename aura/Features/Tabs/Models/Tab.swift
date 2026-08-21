import AppKit
import SwiftData
import SwiftUI

enum TabType: String, Codable {
    case pinned
    case fav
    case normal
}

struct URLUpdate: Codable {
    let href: String
    let title: String
    let favicon: String?
}

// MARK: - Tab

@Model
class Tab: ObservableObject, Identifiable {
    var id: UUID
    var url: URL
    var urlString: String
    var savedURL: URL?
    var title: String
    var favicon: URL? // Add favicon property
    var createdAt: Date
    var lastAccessedAt: Date?

    var type: TabType
    var order: Int
    var faviconLocalFile: URL?
    var backgroundColorHex: String = "#000000"

    @Transient var isPlayingMedia: Bool = false
    @Transient var isLoading: Bool = false
    @Transient @Published var backgroundColor: Color = .black
    @Transient var historyManager: HistoryManager?
    @Transient var downloadManager: DownloadManager?
    @Transient var tabManager: TabManager?
    @Transient var browserPage: BrowserPage?
    @Transient var pageDelegate: TabBrowserPageDelegate?
    @Transient @Published var isWebViewReady: Bool = false
    @Transient @Published var loadingProgress: Double = 10.0
    @Transient var colorUpdated = false
    /// Where the page was scrolled to when it was hibernated, and the URL it belonged
    /// to. Transient on purpose: a scroll offset is not worth a store write, and a cold
    /// launch has no web view to restore it into anyway.
    @Transient var hibernatedScrollOffset: CGPoint?
    @Transient var hibernatedScrollURL: URL?
    @Transient var maybeIsActive = false
    /// Retries exist only for the case where the snapshot cannot be taken at all: a tab
    /// that is not laid out yet. A painted page is done after the first one.
    static let maxSnapshotRetries = 4
    @Transient @Published var hasNavigationError: Bool = false
    @Transient @Published var navigationError: Error?
    @Transient @Published var failedURL: URL?
    @Transient @Published var hoveredLinkURL: String?
    @Transient var isPrivate: Bool = false
    @Transient var passwordCoordinator: PasswordAutofillCoordinator?
    @Transient @Published var passwordOverlayState: PasswordAutofillOverlayState?
    @Transient @Published var passwordTriggerOverlayState: PasswordAutofillOverlayState?

    @Relationship(inverse: \TabContainer.tabs) var container: TabContainer
    /// Set when the tab lives inside a sidebar folder; nil means top level.
    @Relationship var folder: Folder?

    /// Whether this tab is considered alive (recently accessed)
    var isAlive: Bool {
        guard let lastAccessed = lastAccessedAt else { return false }
        let timeout = SettingsStore.shared.tabAliveTimeout
        return Date().timeIntervalSince(lastAccessed) < timeout
    }

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        favicon: URL? = nil,
        container: TabContainer,
        type: TabType = .normal,
        isPlayingMedia: Bool = false,
        order: Int,
        historyManager: HistoryManager? = nil,
        downloadManager: DownloadManager? = nil,
        tabManager: TabManager,
        isPrivate: Bool
    ) {
        let nowDate = Date()
        self.id = id
        self.url = url
        self.urlString = url.absoluteString

        self.title = title
        self.favicon = favicon
        self.createdAt = nowDate
        self.lastAccessedAt = nowDate
        self.type = type
        self.isPlayingMedia = isPlayingMedia
        self.container = container
        self.order = order
        self.historyManager = historyManager
        self.downloadManager = downloadManager
        self.tabManager = tabManager
        self.isPrivate = isPrivate
        self.passwordCoordinator = PasswordAutofillCoordinator(tab: self)
        self.isWebViewReady = false
    }

    func syncBackgroundColorFromHex() {
        backgroundColor = Color(hex: backgroundColorHex)
    }

    /// Call this whenever the color is set
    func updateBackgroundColor(_ color: Color) {
        backgroundColor = color
        backgroundColorHex = color.toHex() ?? "#000000"
    }

    func setFavicon() {
        guard let host = self.url.host else { return }

        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard let faviconURL = FaviconService.shared.faviconURL(for: domain) else { return }

        // Extension-free: the bytes on disk are whatever the site served, .ico or .svg
        // as often as .png, and `NSImage(data:)` sniffs the format anyway.
        let fileName = "\(self.id.uuidString).favicon"
        let saveURL = FileManager.default.faviconDirectory.appendingPathComponent(fileName)

        // In-page navigations re-report the same URL constantly; re-running the download
        // rewrites the same bytes every time. A new domain, or a cache-version bump that
        // left this tab without a file, still refreshes.
        guard self.favicon != faviconURL || !FileManager.default.fileExists(atPath: saveURL.path) else { return }
        self.favicon = faviconURL

        FaviconService.shared
            .downloadAndSaveFavicon(for: domain, faviconURL: faviconURL, to: saveURL) {
                [weak self] sourceURL, success in
                guard let self else { return }
                if success {
                    Task { @MainActor in
                        self.faviconLocalFile = saveURL
                        if let sourceURL {
                            self.favicon = sourceURL
                        }
                    }
                }
            }
    }

    func switchSections(from: Tab, to: Tab) {
        from.type = to.type
        switch to.type {
        case .pinned, .fav:
            from.savedURL = from.url
        case .normal:
            from.savedURL = nil
        }
    }

    /// One snapshot per finished navigation. `takeSnapshot` forces the web content process
    /// to render, so taking them on a timer while the page is busy is a tax on the page
    /// itself; a retry only happens when the snapshot could not be taken at all.
    func updateHeaderColor(retriesLeft: Int = Tab.maxSnapshotRetries) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let page = self.browserPage else { return }
            guard self.pageDelegate?.takeSnapshotAfterLoad(page) == true else {
                if retriesLeft > 0 {
                    self.updateHeaderColor(retriesLeft: retriesLeft - 1)
                }
                return
            }
        }
    }

    func updateHistory() {
        if let historyManager = self.historyManager {
            Task { @MainActor in
                historyManager.record(
                    title: self.title,
                    url: self.url,
                    faviconURL: self.favicon,
                    faviconLocalFile: self.faviconLocalFile,
                    container: self.container
                )
            }
        }
    }

    func setupBrowserPageDelegate(for page: BrowserPage) {
        let delegate = TabBrowserPageDelegate()
        delegate.tab = self
        delegate.mediaController = tabManager?.mediaController
        delegate.passwordCoordinator = passwordCoordinator
        page.delegate = delegate
        pageDelegate = delegate
    }

    func goForward() {
        lastAccessedAt = Date()
        browserPage?.goForward()
        updateHeaderColor()
    }

    func goBack() {
        lastAccessedAt = Date()
        browserPage?.goBack()
        updateHeaderColor()
    }

    func restoreTransientState(
        historyManager: HistoryManager,
        downloadManager: DownloadManager,
        tabManager: TabManager,
        isPrivate: Bool
    ) {
        // aura:// pages render natively in SwiftUI, so they never get a web view.
        if url.isOraInternal {
            // Tabs saved before the rename come back as `ora://`; rewrite them on open.
            let canonical = url.canonicalOraInternal
            if canonical != url {
                url = canonical
                urlString = canonical.absoluteString
            }
            self.historyManager = historyManager
            self.downloadManager = downloadManager
            self.tabManager = tabManager
            self.isPrivate = isPrivate
            return
        }

        // Avoid double initialization
        if browserPage != nil { return }

        if passwordCoordinator == nil {
            passwordCoordinator = PasswordAutofillCoordinator(tab: self)
        }

        let engine = BrowserEngine.shared
        let profile = engine.makeProfile(identifier: container.id, isPrivate: isPrivate)
        let privacySettings = SettingsStore.shared.privacySettings(for: container.id)
        let userScripts = OraBrowserScripts.userScripts() + BrowserPrivacyService.privacyScripts(for: privacySettings)
        let page = engine.makePage(
            profile: profile,
            configuration: BrowserPageConfiguration.oraDefault(
                userScripts: userScripts,
                privacySettings: privacySettings
            ),
            delegate: nil
        )
        browserPage = page

        self.historyManager = historyManager
        self.downloadManager = downloadManager
        self.tabManager = tabManager
        self.isWebViewReady = false
        self.setupBrowserPageDelegate(for: page)
        self.syncBackgroundColorFromHex()
        // Load after a short delay to ensure layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            let url = if self.type != .normal { self.savedURL } else { self.url }
            page.load(URLRequest(url: url ?? self.url))
            self.isWebViewReady = true
        }
    }

    func stopMedia(completed: @escaping () -> Void) {
        guard let page = browserPage else {
            completed()
            return
        }

        let js = """
        document.querySelectorAll('video, audio').forEach(el => {
            try {
                el.pause();
                el.src = '';
                el.load();
            } catch (e) {}
        });
        """
        page.evaluateJavaScript(js) { [weak self] _, _ in
            page.closeMediaPresentations {
                page.teardown()
                if self?.browserPage === page {
                    self?.browserPage = nil
                    self?.pageDelegate = nil
                }
                completed()
            }
        }
    }

    func loadURL(_ urlString: String) {
        lastAccessedAt = Date()
        let input = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Try to construct a direct URL (has scheme or valid domain+TLD/IP)
        if let directURL = constructURL(from: input) {
            navigate(to: directURL)
            return
        }

        // 2) Otherwise, treat as a search query using the selected search engine
        let searchEngineService = SearchEngineService()
        if let engine = searchEngineService.getDefaultSearchEngine(for: self.container.id),
           let searchURL = searchEngineService.createSearchURL(for: engine, query: input)
        {
            navigate(to: searchURL)
            return
        }

        // 3) Fallback to Google if for some reason engine lookup fails
        if let fallbackURL = URL(string: "https://www.google.com/search?client=safari&rls=en&ie=UTF-8&oe=UTF-8&q="
            + (input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        ) {
            navigate(to: fallbackURL)
        }
    }

    /// A tab showing an aura:// page has no web view, so navigating away from one has to
    /// build it first; `restoreTransientState` loads `url` once the page exists. Going the
    /// other way tears the web view down instead, which drops WebKit's back list: back from
    /// the first page opened out of aura://home cannot return to the home page.
    private func navigate(to target: URL) {
        if target.isOraInternal {
            destroyWebView()
            url = target
            urlString = target.absoluteString
            if target.isOraHome {
                title = "New Tab"
                favicon = nil
                faviconLocalFile = nil
            } else if target.isOraExtensions {
                title = "Extensions"
                favicon = nil
                faviconLocalFile = nil
            }
            return
        }
        guard let page = browserPage else {
            url = target
            urlString = target.absoluteString
            if let historyManager, let downloadManager, let tabManager {
                restoreTransientState(
                    historyManager: historyManager,
                    downloadManager: downloadManager,
                    tabManager: tabManager,
                    isPrivate: isPrivate
                )
            }
            return
        }
        page.load(URLRequest(url: target))
    }

    func destroyWebView() {
        browserPage?.teardown()
        browserPage = nil
        pageDelegate = nil
        isWebViewReady = false
    }

    func setNavigationError(_ error: Error, for url: URL?) {
        DispatchQueue.main.async {
            self.hasNavigationError = true
            self.navigationError = error
            self.failedURL = url
        }
    }

    func clearNavigationError() {
        DispatchQueue.main.async {
            self.hasNavigationError = false
            self.navigationError = nil
            self.failedURL = nil
        }
    }

    func retryNavigation() {
        // Don't clear error state immediately - let onStart callback handle it
        // This prevents showing white background before navigation begins
        if let url = failedURL {
            let request = URLRequest(url: url)
            browserPage?.load(request)
        }
    }

    func continueToInsecureSite() {
        let url = failedURL ?? self.url
        guard let host = url.host else { return }
        browserPage?.bypassSSL(for: host)
        clearNavigationError()
        browserPage?.load(URLRequest(url: url))
    }

    var canGoBack: Bool {
        browserPage?.canGoBack ?? false
    }

    var canGoForward: Bool {
        browserPage?.canGoForward ?? false
    }

    var currentPageURL: URL? {
        browserPage?.currentURL
    }

    var pageWindow: NSWindow? {
        browserPage?.window
    }

    func reload() {
        browserPage?.reload()
    }

    func refreshBrowserPageForPrivacySettings() {
        guard isWebViewReady,
              let historyManager,
              let downloadManager,
              let tabManager
        else {
            return
        }

        destroyWebView()
        restoreTransientState(
            historyManager: historyManager,
            downloadManager: downloadManager,
            tabManager: tabManager,
            isPrivate: isPrivate
        )
    }

    func evaluateJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        browserPage?.evaluateJavaScript(script, completion: completion)
    }

    func takeSnapshot(
        configuration: BrowserSnapshotConfiguration,
        completion: @escaping (NSImage?, Error?) -> Void
    ) {
        browserPage?.takeSnapshot(configuration: configuration, completion: completion)
    }
}

extension FileManager {
    /// Bumped to v2 when favicons started being stored as their original bytes. The old
    /// folder holds 16 px TIFFs written under a `.png` name, so it is dropped outright
    /// and every tab refetches at full resolution.
    var faviconDirectory: URL {
        let root = urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Favicons")
        let dir = root.appendingPathComponent("v2")
        if !fileExists(atPath: dir.path) {
            let legacy = (try? contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for file in legacy where file.lastPathComponent != "v2" {
                try? removeItem(at: file)
            }
            try? createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        // swiftlint:disable:next identifier_name
        let r, g, b, a: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
            a = 1.0
        case 8:
            r = Double((int >> 24) & 0xFF) / 255
            g = Double((int >> 16) & 0xFF) / 255
            b = Double((int >> 8) & 0xFF) / 255
            a = Double(int & 0xFF) / 255
        default:
            return nil
        }

        self.init(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    func toHex() -> String? {
        guard let color = usingColorSpace(.deviceRGB) else { return nil }
        // swiftlint:disable:next identifier_name
        let r = Int(color.redComponent * 255)
        // swiftlint:disable:next identifier_name
        let g = Int(color.greenComponent * 255)
        // swiftlint:disable:next identifier_name
        let b = Int(color.blueComponent * 255)
        // swiftlint:disable:next identifier_name
        let a = Int(color.alphaComponent * 255)

        return a < 255
            ? String(format: "#%02X%02X%02X%02X", r, g, b, a)
            : String(format: "#%02X%02X%02X", r, g, b)
    }
}
