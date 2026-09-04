import AppKit
import Foundation
import UniformTypeIdentifiers
@preconcurrency import WebKit

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var delegate: BrowserPageDelegate?

    private let webView: AuraWebView
    private let messageNames: [String]
    private var originalURL: URL?
    private(set) var lastCommittedURL: URL?
    private(set) var isDownloadNavigation = false
    private(set) var sslBypassedHosts: Set<String> = []
    private var isReadyForNavigation = false
    private var pendingLoadRequest: URLRequest?
    private var pendingReload = false
    /// Last report from the page-side `contextmenu` listener. WebKit fires the DOM event
    /// before AppKit builds its menu, so by `willOpenMenu` this already describes the
    /// element under the pointer.
    /// Written only by `cacheContextMenuInfo`, which lives in BrowserPage+Actions.swift.
    var lastContextMenuInfo = BrowserContextMenuInfo()

    /// Kept so a `window.open()` popup adopted from this page can be rebuilt with the
    /// same message handlers, user scripts and preferences.
    private let profile: BrowserEngineProfile
    private let pageConfiguration: BrowserPageConfiguration
    /// Host of the extension whose own pages this web view was built for, or nil for an
    /// ordinary page. See `ExtensionManager.pageConfiguration(hosting:)`.
    let hostedExtensionHost: String?

    /// `hosting` is the address the page is about to load. When that is an extension's own
    /// page, the web view is built on the extension's configuration instead of the
    /// profile's: that one carries the controller's data store and process pool, and it is
    /// the only kind WebKit serves such a page to.
    convenience init(
        profile: BrowserEngineProfile,
        configuration: BrowserPageConfiguration,
        delegate: BrowserPageDelegate?,
        hosting url: URL? = nil
    ) {
        if let url, let extensionConfiguration = MainActor.assumeIsolated({
            ExtensionManager.shared.pageConfiguration(hosting: url)
        }) {
            self.init(
                profile: profile,
                configuration: configuration,
                webConfiguration: extensionConfiguration,
                delegate: delegate,
                hostedExtensionHost: url.host
            )
            return
        }
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = profile.dataStore
        // Private tabs get the injected bundle too: request blocking is not
        // privacy-sensitive, and the pool carries no website data.
        AuraWebBundle.apply(to: webConfiguration)
        self.init(
            profile: profile,
            configuration: configuration,
            webConfiguration: webConfiguration,
            delegate: delegate
        )
    }

    /// A `window.open()` popup. WebKit hands over the configuration the new window has
    /// to be built on, and only a web view created from *that object* keeps
    /// `window.opener` wired up, which is how OAuth and SSO popups hand their result
    /// back to the page that opened them. The opener's data store and process pool ride
    /// along inside it and are left untouched; everything else is registered again here.
    ///
    /// Ported from Nook, `Nook/Models/Tab/Tab.swift` by Maciek Bagiński (GPL-3.0).
    convenience init(
        adopting webConfiguration: WKWebViewConfiguration,
        profile: BrowserEngineProfile,
        configuration: BrowserPageConfiguration,
        delegate: BrowserPageDelegate?
    ) {
        self.init(
            profile: profile,
            configuration: configuration,
            webConfiguration: webConfiguration,
            delegate: delegate
        )
    }

    private init(
        profile: BrowserEngineProfile,
        configuration: BrowserPageConfiguration,
        webConfiguration: WKWebViewConfiguration,
        delegate: BrowserPageDelegate?,
        hostedExtensionHost: String? = nil
    ) {
        self.profile = profile
        self.pageConfiguration = configuration
        self.hostedExtensionHost = hostedExtensionHost
        webConfiguration.applicationNameForUserAgent = configuration.userAgent
        webConfiguration.allowsAirPlayForMediaPlayback = configuration.allowsAirPlayForMediaPlayback
        webConfiguration.preferences.setValue(
            configuration.allowsInspectableDebugging,
            forKey: "developerExtrasEnabled"
        )
        webConfiguration.preferences.setValue(
            configuration.allowsPictureInPicture,
            forKey: "allowsPictureInPictureMediaPlayback"
        )
        webConfiguration.preferences.setValue(configuration.allowsJavaScript, forKey: "javaScriptEnabled")
        webConfiguration.preferences.setValue(
            configuration.allowsJavaScriptWindowsAutomatically,
            forKey: "javaScriptCanOpenWindowsAutomatically"
        )
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically =
            configuration.allowsJavaScriptWindowsAutomatically
        webConfiguration.preferences.isElementFullscreenEnabled = true
        webConfiguration.mediaTypesRequiringUserActionForPlayback =
            configuration.mediaPlaybackRequiresUserAction ? .all : []

        Self.applyUserPreferences(to: webConfiguration)

        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = configuration.allowsJavaScript
        webConfiguration.defaultWebpagePreferences = webpagePreferences

        // A fresh controller, also on the adopting path: the configuration WebKit hands
        // over for a popup shares the opener's controller, so adding our handlers to it
        // would register them on the opener a second time (and `add` throws on a name
        // that is already taken).
        let contentController = WKUserContentController()
        webConfiguration.userContentController = contentController

        MainActor.assumeIsolated {
            ExtensionManager.shared.attach(to: webConfiguration, isPrivate: profile.isPrivate)
        }
        messageNames = configuration.scriptMessageNames
        webView = AuraWebView(frame: .zero, configuration: webConfiguration)
        self.delegate = delegate

        super.init()

        for messageName in configuration.scriptMessageNames {
            // A weak proxy keeps the content controller from retaining the page,
            // so a Tab released without an explicit teardown() can't leak the webview.
            contentController.add(WeakScriptMessageHandler(target: self), name: messageName)
        }
        for script in configuration.userScripts {
            let userScript = WKUserScript(
                source: script.source,
                injectionTime: mapInjectionTime(script.injectionTime),
                forMainFrameOnly: script.forMainFrameOnly
            )
            contentController.addUserScript(userScript)
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        installContextMenuBridge()
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = configuration.allowsBackForwardNavigationGestures
        webView.wantsLayer = true
        webView.isInspectable = configuration.allowsInspectableDebugging
        webView.layer?.isOpaque = true

        BrowserPrivacyService.shared.prepareConfiguration(
            webConfiguration,
            spaceID: profile.identifier
        ) { [weak self] in
            self?.isReadyForNavigation = true
            self?.flushPendingNavigationIfNeeded()
        }
    }

    /// The one place the user's page-level preferences reach WebKit. Read from
    /// `UserDefaults` rather than `SettingsStore` because a page is built off the main
    /// actor. New web views pick a change up straight away; open ones on their next load.
    static func applyUserPreferences(to configuration: WKWebViewConfiguration) {
        let minimumFontSize = UserDefaults.standard.double(forKey: SettingsStore.minimumFontSizeKey)
        guard minimumFontSize > 0 else { return }
        configuration.preferences.minimumFontSize = CGFloat(minimumFontSize)
    }

    var contentView: NSView {
        webView
    }

    /// What this page was built with. A user script cannot be swapped on a live page, so
    /// this, not the store, is what the page is doing right now.
    var privacySettings: SpacePrivacySettings {
        pageConfiguration.privacySettings
    }

    /// The concrete web view, so the actions split into BrowserPage+Actions.swift can
    /// reach it without opening `webView` up to the rest of the app.
    var auraWebView: AuraWebView {
        webView
    }

    var window: NSWindow? {
        webView.window
    }

    var currentURL: URL? {
        webView.url
    }

    var title: String? {
        webView.title
    }

    var canGoBack: Bool {
        webView.canGoBack
    }

    var canGoForward: Bool {
        webView.canGoForward
    }

    var isLoading: Bool {
        webView.isLoading
    }

    var estimatedProgress: Double {
        webView.estimatedProgress
    }

    /// The layout scale the page is drawn at. Not `magnification`: that one is the
    /// pinch gesture, which resets itself and is not what a site's remembered zoom
    /// means. `pageZoom` belongs to the web view, so it outlives a navigation and has
    /// to be reassigned whenever the tab lands on a different site.
    var zoom: Double {
        get { Double(webView.pageZoom) }
        set { webView.pageZoom = CGFloat(newValue) }
    }

    func load(_ request: URLRequest) {
        guard isReadyForNavigation else {
            pendingLoadRequest = request
            pendingReload = false
            pendingSessionState = nil
            return
        }

        performLoad(request)
    }

    /// Where every load ends up, so a `file://` URL is handled the same whether it
    /// arrived now or was parked waiting for the space's privacy configuration.
    ///
    /// A sandboxed app cannot hand WebKit a file URL through `load(_:)`: the web process
    /// is given no read extension for it and the load fails with a permissions error.
    /// `loadFileURL(_:allowingReadAccessTo:)` is what issues one. Read access is granted
    /// on the file's folder rather than the file, which is the smallest scope that still
    /// lets a local HTML page load the stylesheet and images sitting next to it.
    private func performLoad(_ request: URLRequest) {
        if let url = request.url, url.isFileURL {
            // The stored grant is opened first, and this is the only place that covers
            // every route to a local file: a restored tab at launch, a tray row, a typed
            // path. `assumeIsolated` is safe because a load is always driven from the main
            // thread, which WebKit requires of every call on this object.
            _ = MainActor.assumeIsolated { FileAccessStore.shared.beginAccess(to: url) }
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        webView.load(request)
    }

    func reload() {
        guard isReadyForNavigation else {
            pendingReload = true
            pendingLoadRequest = nil
            pendingSessionState = nil
            return
        }

        webView.reload()
    }

    /// A session blob waiting on the privacy configuration, the same way a request does.
    private var pendingSessionState: Data?

    /// Puts WebKit's own session state back: the back/forward list with its titles, which
    /// item is current, and where that item was scrolled to. WebKit loads that item as a
    /// result, which is why this replaces the load a restored tab would otherwise do
    /// rather than joining it, and why it goes through the same gate: a restored tab must
    /// not start fetching before the space's content rules are attached.
    func restoreSession(_ state: Data) {
        guard isReadyForNavigation else {
            pendingSessionState = state
            pendingLoadRequest = nil
            pendingReload = false
            return
        }

        webView.interactionState = state
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func evaluateJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        webView.evaluateJavaScript(script, completionHandler: completion)
    }

    func takeSnapshot(
        configuration: BrowserSnapshotConfiguration,
        completion: @escaping (NSImage?, Error?) -> Void
    ) {
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.afterScreenUpdates = configuration.afterScreenUpdates
        if let rect = configuration.rect {
            snapshotConfiguration.rect = rect
        }
        if let width = configuration.snapshotWidth {
            snapshotConfiguration.snapshotWidth = NSNumber(value: Double(width))
        }
        webView.takeSnapshot(with: snapshotConfiguration, completionHandler: completion)
    }

    func closeMediaPresentations(completion: @escaping () -> Void) {
        webView.closeAllMediaPresentations(completionHandler: completion)
    }

    func teardown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onContextMenu = nil
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for messageName in messageNames {
            controller.removeScriptMessageHandler(forName: messageName)
        }
        webView.removeFromSuperview()
    }

    func bypassSSL(for host: String) {
        sslBypassedHosts.insert(host)
    }

    private func flushPendingNavigationIfNeeded() {
        if let pendingSessionState {
            self.pendingSessionState = nil
            webView.interactionState = pendingSessionState
            return
        }

        if let pendingLoadRequest {
            self.pendingLoadRequest = nil
            performLoad(pendingLoadRequest)
            return
        }

        if pendingReload {
            pendingReload = false
            webView.reload()
        }
    }

    private func emitNavigationEvent(
        phase: BrowserNavigationPhase,
        url: URL?,
        title: String?,
        progress: Double,
        isLoading: Bool
    ) {
        delegate?.browserPage(
            self,
            didUpdateNavigation: BrowserNavigationEvent(
                phase: phase,
                url: url,
                title: title,
                progress: progress,
                isLoading: isLoading
            )
        )
    }

    private func handleCancelledNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func mapInjectionTime(_ injectionTime: BrowserUserScriptInjectionTime) -> WKUserScriptInjectionTime {
        switch injectionTime {
        case .atDocumentStart:
            .atDocumentStart
        case .atDocumentEnd:
            .atDocumentEnd
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "contextMenu" {
            cacheContextMenuInfo(message.body)
            return
        }

        delegate?.browserPage(
            self,
            didReceiveScriptMessage: BrowserScriptMessage(name: message.name, body: message.body)
        )
    }

    /// The `preferences` variant is the only one implemented: WebKit calls just one of
    /// the two, and this is where `allowsContentJavaScript` can be set per navigation.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        applyJavaScriptPolicy(to: preferences, for: navigationAction, in: webView)

        // `<a download>` and anything else WebKit has already decided is a file rather
        // than a page. Without this the link just navigated and the download never
        // reached `navigationAction:didBecome:`.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }

        let action = BrowserNavigationAction(
            request: navigationAction.request,
            modifierFlags: navigationAction.modifierFlags,
            buttonNumber: navigationAction.buttonNumber,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            isUserInitiated: navigationAction.navigationType == .linkActivated
                || navigationAction.navigationType == .formSubmitted
                || navigationAction.navigationType == .other
        )

        switch delegate?.browserPage(self, decidePolicyFor: action) ?? .allow {
        case .allow:
            // After the delegate, so a navigation it routes elsewhere is never re-issued
            // here. `targetFrame == nil` is a window the page is about to open, and a
            // load on this web view would put that page in this tab instead.
            if let signalled = BrowserPrivacyService.requestSignallingGlobalPrivacyControl(
                navigationAction.request,
                privacySettings: pageConfiguration.privacySettings,
                isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                isBackForward: navigationAction.navigationType == .backForward
            ) {
                decisionHandler(.cancel, preferences)
                webView.load(signalled)
                return
            }
            decisionHandler(.allow, preferences)
        case .cancel:
            decisionHandler(.cancel, preferences)
        case .openInNewTab:
            if let url = navigationAction.request.url {
                delegate?.browserPage(self, didRequestOpenInNewTab: url)
            }
            decisionHandler(.cancel, preferences)
        }
    }

    private func applyJavaScriptPolicy(
        to preferences: WKWebpagePreferences,
        for navigationAction: WKNavigationAction,
        in webView: WKWebView
    ) {
        // A nil target frame means a brand-new frame or window, so the request URL is
        // the document being loaded. A real subframe is judged by the main document's
        // host instead, otherwise a blocked page could smuggle scripts in via iframes.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let policyURL = isMainFrame
            ? navigationAction.request.url
            : (webView.url ?? navigationAction.request.url)
        guard let policyURL else { return }

        preferences.allowsContentJavaScript = MainActor.assumeIsolated {
            JavaScriptPolicyService.shared.isAllowed(for: policyURL)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !isDownloadNavigation {
            originalURL = lastCommittedURL
            emitNavigationEvent(
                phase: .started,
                url: webView.url,
                title: webView.title,
                progress: 10.0,
                isLoading: true
            )
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if !isDownloadNavigation {
            lastCommittedURL = webView.url
            emitNavigationEvent(
                phase: .committed,
                url: webView.url,
                title: webView.title,
                progress: webView.estimatedProgress * 100.0,
                isLoading: true
            )
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isDownloadNavigation {
            lastCommittedURL = webView.url
            emitNavigationEvent(
                phase: .finished,
                url: webView.url,
                title: webView.title,
                progress: webView.estimatedProgress * 100.0,
                isLoading: false
            )
            originalURL = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isDownloadNavigation else {
            originalURL = nil
            return
        }

        emitNavigationEvent(
            phase: .finished,
            url: webView.url,
            title: webView.title,
            progress: 100.0,
            isLoading: false
        )

        if !handleCancelledNavigationError(error) {
            delegate?.browserPage(self, didFailNavigationWith: error, failingURL: webView.url)
        }
        originalURL = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isDownloadNavigation else {
            originalURL = nil
            return
        }

        emitNavigationEvent(
            phase: .finished,
            url: webView.url,
            title: webView.title,
            progress: 100.0,
            isLoading: false
        )

        if handleCancelledNavigationError(error) {
            return
        }

        let nsError = error as NSError
        let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        delegate?.browserPage(self, didFailNavigationWith: error, failingURL: failingURL)
        originalURL = nil
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust,
           sslBypassedHosts.contains(challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    @available(macOS 11.3, *)
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition = Self.responseDisposition(
            canShowMIMEType: navigationResponse.canShowMIMEType,
            contentDisposition: (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")
        )

        if disposition == .inline {
            if navigationResponse.isForMainFrame {
                isDownloadNavigation = false
                originalURL = nil
            }
            decisionHandler(.allow)
            return
        }

        // Only a main-frame download replaces the page; a subframe download
        // must not suppress the main frame's navigation events.
        if navigationResponse.isForMainFrame {
            isDownloadNavigation = true
            emitNavigationEvent(
                phase: .finished,
                url: originalURL,
                title: webView.title,
                progress: 0,
                isLoading: false
            )
        }
        decisionHandler(.download)
    }

    /// A download that never produced a response: `<a download>`, or a policy decision
    /// of `.download` taken on the navigation action.
    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        guard let downloadURL = navigationAction.request.url else { return }
        let task = BrowserDownloadTask(download: download, originalURL: downloadURL)
        delegate?.browserPage(self, didStartDownload: task)
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        defer {
            // Always clear the flag, even without a response URL — otherwise the
            // tab's navigation events stay suppressed forever.
            if navigationResponse.isForMainFrame {
                isDownloadNavigation = false
                originalURL = nil
            }
        }
        guard let downloadURL = navigationResponse.response.url else { return }
        let task = BrowserDownloadTask(download: download, originalURL: downloadURL)
        delegate?.browserPage(self, didStartDownload: task)
    }

    /// The selector has to match WebKit's exactly or WebKit falls back to its own raw
    /// dialog, which is what happened while this was declared without `type:`. The type
    /// is also the only thing that says whether the page wants the camera, the
    /// microphone or both, and each is a separate grant.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let kind: BrowserPermissionKind = switch type {
        case .camera: .camera
        case .microphone: .microphone
        case .cameraAndMicrophone: .cameraAndMicrophone
        @unknown default: .cameraAndMicrophone
        }

        guard let delegate else {
            // WebKit waits forever on an uncalled handler, and a page with no delegate
            // has no window to ask in.
            decisionHandler(.deny)
            return
        }

        delegate.browserPage(self, requestPermission: kind, origin: Self.originURL(origin)) { decision in
            switch decision {
            case .grant: decisionHandler(.grant)
            case .deny: decisionHandler(.deny)
            case .prompt: decisionHandler(.prompt)
            }
        }
    }

    /// `WKSecurityOrigin` reports port 0 for a scheme's default port, so the port is
    /// only spelled out when the page really is on an unusual one.
    private static func originURL(_ origin: WKSecurityOrigin) -> URL? {
        let base = "\(origin.protocol)://\(origin.host)"
        return URL(string: origin.port == 0 ? base : "\(base):\(origin.port)")
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        delegate?.browserPage(
            self,
            runOpenPanelWith: BrowserOpenPanelOptions(
                allowsDirectories: parameters.allowsDirectories,
                allowsMultipleSelection: parameters.allowsMultipleSelection
            ),
            completion: completionHandler
        )
    }

    /// Returning nil here is what severed `window.opener`: the page that called
    /// `window.open()` got back a null handle, and an OAuth or SSO popup that posts its
    /// token to `window.opener` had nowhere to post it. The popup is built on WebKit's
    /// own configuration instead and handed to the delegate to host in a tab; only if
    /// nobody takes it does this fall back to opening a plain new tab.
    ///
    /// Ported from Nook, `Nook/Models/Tab/Tab.swift` by Maciek Bagiński (GPL-3.0).
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = BrowserPage(
            adopting: configuration,
            profile: profile,
            configuration: pageConfiguration,
            delegate: nil
        )
        if delegate?.browserPage(self, didRequestAdopt: popup, for: navigationAction.request.url) == true {
            return popup.auraWebView
        }

        popup.teardown()
        if let url = navigationAction.request.url {
            delegate?.browserPage(self, didRequestOpenInNewTab: url)
        }
        return nil
    }

    // MARK: - WebContent crashes

    /// Consecutive crashes inside the 30 s window below. Reset once the page manages to
    /// stay up that long.
    private var webProcessCrashCount = 0
    private var lastWebProcessCrash = Date.distantPast

    /// How long to wait before reloading after the nth crash in a burst, or nil to stop
    /// retrying: after four the machine is in a bad state (XPC services still restarting
    /// after a wake, usually) and each reload only spawns another doomed process.
    static func crashReloadDelay(forCrashCount crashCount: Int) -> TimeInterval? {
        guard crashCount <= 4 else { return nil }
        return Double(crashCount) * 2.0
    }

    /// A crashed WebContent process leaves the tab showing nothing at all, with no
    /// navigation callback to say so. Reload it, backing off each time so a page that
    /// crashes on load cannot spin.
    ///
    /// Ported from Nook, `Nook/Models/Tab/Tab.swift` by Maciek Bagiński (GPL-3.0).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        if now.timeIntervalSince(lastWebProcessCrash) > 30 {
            webProcessCrashCount = 0
        }
        webProcessCrashCount += 1
        lastWebProcessCrash = now

        emitNavigationEvent(
            phase: .finished,
            url: webView.url,
            title: webView.title,
            progress: 0,
            isLoading: false
        )

        guard let delay = Self.crashReloadDelay(forCrashCount: webProcessCrashCount) else {
            // about:blank rather than another reload: it stops WebKit putting the
            // crashing document straight back into the next process it spawns.
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
            webView?.reload()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        // The page's alert() returns only once the dialog is dismissed.
        guard let delegate else { return completionHandler() }
        delegate.browserPage(self, runJavaScriptAlert: message, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        delegate?.browserPage(self, runJavaScriptConfirm: message, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        delegate?.browserPage(
            self,
            runJavaScriptPrompt: prompt,
            defaultText: defaultText,
            completion: completionHandler
        )
    }
}
