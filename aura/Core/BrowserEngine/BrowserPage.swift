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
    private let spaceID: UUID
    /// The scripts every page gets. Kept because advanced blocking has to replace the
    /// whole user script list per navigation: WebKit can only remove all of them at once.
    private let baseUserScripts: [BrowserUserScript]
    private var hasAdvancedScripts = false
    private var advancedBlockingObserver: NSObjectProtocol?
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

    init(
        profile: BrowserEngineProfile,
        configuration: BrowserPageConfiguration,
        delegate: BrowserPageDelegate?
    ) {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.applicationNameForUserAgent = configuration.userAgent
        webConfiguration.websiteDataStore = profile.dataStore
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

        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = configuration.allowsJavaScript
        webConfiguration.defaultWebpagePreferences = webpagePreferences

        let contentController = WKUserContentController()
        webConfiguration.userContentController = contentController

        MainActor.assumeIsolated {
            ExtensionManager.shared.attach(to: webConfiguration, isPrivate: profile.isPrivate)
        }
        messageNames = configuration.scriptMessageNames
        spaceID = profile.identifier
        baseUserScripts = configuration.userScripts
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
        if let layer = webView.layer {
            layer.isOpaque = true
            layer.drawsAsynchronously = true
        }

        MainActor.assumeIsolated {
            AdvancedBlockingService.shared.prepare(spaceID: profile.identifier)
        }
        observeAdvancedBlockingChanges()

        BrowserPrivacyService.shared.prepareConfiguration(
            webConfiguration,
            spaceID: profile.identifier
        ) { [weak self] in
            self?.isReadyForNavigation = true
            self?.flushPendingNavigationIfNeeded()
        }
    }

    var contentView: NSView {
        webView
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

    func load(_ request: URLRequest) {
        guard isReadyForNavigation else {
            pendingLoadRequest = request
            pendingReload = false
            return
        }

        webView.load(request)
    }

    func reload() {
        guard isReadyForNavigation else {
            pendingReload = true
            pendingLoadRequest = nil
            return
        }

        webView.reload()
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
        webView.takeSnapshot(with: snapshotConfiguration, completionHandler: completion)
    }

    func closeMediaPresentations(completion: @escaping () -> Void) {
        webView.closeAllMediaPresentations(completionHandler: completion)
    }

    func teardown() {
        if let advancedBlockingObserver {
            NotificationCenter.default.removeObserver(advancedBlockingObserver)
            self.advancedBlockingObserver = nil
        }
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
        if let pendingLoadRequest {
            self.pendingLoadRequest = nil
            webView.load(pendingLoadRequest)
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
        if message.name == "advancedBlocking" {
            applyAdvancedBlockingToFrame(message)
            return
        }

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

        let action = BrowserNavigationAction(
            request: navigationAction.request,
            modifierFlags: navigationAction.modifierFlags,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            isUserInitiated: navigationAction.navigationType == .linkActivated
                || navigationAction.navigationType == .formSubmitted
                || navigationAction.navigationType == .other
        )

        switch delegate?.browserPage(self, decidePolicyFor: action) ?? .allow {
        case .allow:
            if stripTrackingParametersIfNeeded(for: navigationAction) {
                decisionHandler(.cancel, preferences)
                return
            }
            applyAdvancedBlocking(for: navigationAction)
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
           sslBypassedHosts.contains(challenge.protectionSpace.host)
        {
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
        if navigationResponse.canShowMIMEType {
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

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let pageURL = URL(string: "\(origin.protocol)://\(origin.host):\(origin.port)")
        delegate?.browserPage(self, requestPermission: .mediaCapture, origin: pageURL) { decision in
            switch decision {
            case .grant: decisionHandler(.grant)
            case .deny: decisionHandler(.deny)
            case .prompt: decisionHandler(.prompt)
            }
        }
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

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            delegate?.browserPage(self, didRequestOpenInNewTab: url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        delegate?.browserPage(self, runJavaScriptAlert: message)
        completionHandler()
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

// MARK: - Advanced blocking

/// The rules WebKit's content blocking format cannot express are applied here: the
/// engine is queried per navigation and the result becomes a document-start user script.
private extension BrowserPage {
    func observeAdvancedBlockingChanges() {
        advancedBlockingObserver = NotificationCenter.default.addObserver(
            forName: AdvancedBlockingService.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let currentURL = self.webView.url else { return }
            // A per-site change only affects the pages on that site; a global one hits all.
            if let changedHost = notification.userInfo?["host"] as? String,
               registrableDomain(from: currentURL) != changedHost
            {
                return
            }
            self.webView.reload()
        }
    }

    /// Cancels and re-issues a document navigation with `$removeparam` parameters gone.
    /// Returns true when it took over the navigation.
    func stripTrackingParametersIfNeeded(for navigationAction: WKNavigationAction) -> Bool {
        // Only a plain GET into the main frame can be re-issued safely: a POST would lose
        // its body and a back/forward entry would be rewritten under the user.
        guard navigationAction.targetFrame?.isMainFrame == true,
              navigationAction.navigationType != .backForward,
              (navigationAction.request.httpMethod ?? "GET") == "GET",
              let url = navigationAction.request.url
        else {
            return false
        }

        let stripped = MainActor.assumeIsolated { () -> URL? in
            let service = AdvancedBlockingService.shared
            guard service.isEnabled(for: url) else { return nil }
            return service.strippedURL(for: url, spaceID: spaceID)
        }
        guard let stripped else { return false }

        var request = navigationAction.request
        request.url = stripped
        DispatchQueue.main.async { [weak self] in
            self?.webView.load(request)
        }
        return true
    }

    func applyAdvancedBlocking(for navigationAction: WKNavigationAction) {
        guard navigationAction.targetFrame?.isMainFrame ?? true,
              let url = navigationAction.request.url
        else {
            return
        }

        let payload = MainActor.assumeIsolated { () -> AdvancedBlockingPayload? in
            let service = AdvancedBlockingService.shared
            guard service.isEnabled(for: url) else { return nil }
            return service.payload(for: url, spaceID: spaceID)
        }
        installUserScripts(advanced: payload)
    }

    /// A cross-origin subframe got the top document's rules, which are not its own, so it
    /// asked for a fresh lookup against its own URL.
    func applyAdvancedBlockingToFrame(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString),
              !message.frameInfo.isMainFrame
        else {
            return
        }

        let topURL = webView.url
        let script = MainActor.assumeIsolated { () -> String? in
            let service = AdvancedBlockingService.shared
            // The per-site switch belongs to the site the user is looking at, not the frame.
            guard service.isEnabled(for: topURL ?? url) else { return nil }
            return service.frameScript(for: url, topURL: topURL, spaceID: spaceID)
        }
        guard let script else { return }

        webView.evaluateJavaScript(script, in: message.frameInfo, in: .page) { _ in }
    }

    /// Replaces the whole user script list, because `WKUserContentController` can only
    /// remove all of them at once. Skipped entirely when there is nothing to change.
    func installUserScripts(advanced payload: AdvancedBlockingPayload?) {
        let advancedScripts = payload.map { AdvancedBlockingService.shared.userScripts(for: $0) } ?? []
        guard !advancedScripts.isEmpty || hasAdvancedScripts else { return }
        hasAdvancedScripts = !advancedScripts.isEmpty

        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for script in baseUserScripts + advancedScripts {
            controller.addUserScript(
                WKUserScript(
                    source: script.source,
                    injectionTime: mapInjectionTime(script.injectionTime),
                    forMainFrameOnly: script.forMainFrameOnly
                )
            )
        }
    }
}
