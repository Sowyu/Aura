import AppKit
import SwiftUI

/// Remembers the URL a tab last recorded a visit for. The page script reports on every
/// `<title>` mutation, so without this a page that keeps renaming itself counts as a new
/// visit every 150 ms.
struct HistoryVisitGate {
    private var lastRecordedURL: URL?
    private var lastRecorded: (title: String, favicon: URL?)?

    enum Change: Equatable {
        /// Nothing the row stores has changed, so there is nothing to fetch or save.
        case none
        /// Same page, new title or icon: refresh the row, do not count a visit.
        case details
        /// A different URL: a real visit.
        case visit
    }

    /// What a page-script or navigation update means for history. A retitling page
    /// sends the same URL many times a second; only the first of each title is work.
    mutating func change(url: URL, title: String, favicon: URL?) -> Change {
        defer {
            lastRecordedURL = url
            lastRecorded = (title, favicon)
        }
        if lastRecordedURL != url { return .visit }
        if let lastRecorded, lastRecorded.title == title, lastRecorded.favicon == favicon { return .none }
        return .details
    }

    /// True when `url` is a move away from the last recorded one, so it is a real visit.
    mutating func countsAsVisit(_ url: URL) -> Bool {
        change(url: url, title: lastRecorded?.title ?? "", favicon: lastRecorded?.favicon) == .visit
    }
}

/// The one snapshot the chrome colour needs. Rendering the whole view per finished
/// navigation makes the web content process draw a frame nobody looks at, so the
/// snapshot is scoped to the strip the colour is averaged from and downscaled on the
/// way out.
enum HeaderColorSnapshot {
    /// How much of the top of the page the colour is averaged over, in points.
    static let stripHeight: CGFloat = 24
    /// The whole view at 32px wide, never a rect: a rect-scoped snapshot is a known
    /// WebKit flash trigger (see `BrowserSnapshotConfiguration`). The strip is cut out
    /// of the tiny bitmap afterwards, which costs nothing.
    static func configuration(for viewSize: CGSize) -> BrowserSnapshotConfiguration {
        .thumbnail
    }

    /// The top strip of the scaled bitmap, in pixels, for a view of `viewSize` points.
    static func stripRect(imageSize: CGSize, viewSize: CGSize) -> CGRect {
        guard viewSize.height > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }
        let fraction = min(1, stripHeight / viewSize.height)
        let height = max(1, (imageSize.height * fraction).rounded(.up))
        return CGRect(x: 0, y: 0, width: imageSize.width, height: height)
    }

    /// A snapshot is only worth a forced render when someone can see the result: a
    /// background tab has no window, and a window that is not key is behind something.
    static func shouldSnapshot(windowIsKey: Bool, isVisibleTab: Bool) -> Bool {
        windowIsKey && isVisibleTab
    }
}

final class TabBrowserPageDelegate: BrowserPageDelegate {
    weak var tab: Tab?
    weak var mediaController: MediaController?
    weak var passwordCoordinator: PasswordAutofillCoordinator?

    private var progressResetWorkItem: DispatchWorkItem?
    /// One delegate per tab, so this is the tab's own last-recorded URL.
    private var historyGate = HistoryVisitGate()
    /// A load finished while the tab was hidden or its window was in the background.
    /// `TabManager.activateTab` asks for the colour again when the tab comes up; this
    /// covers the rest, on the next navigation or title report that arrives while the
    /// tab is visible.
    private var pendingHeaderColor = false
    /// How many times this tab has re-tried an extension page that was not there yet.
    /// See `retriedExtensionPage`.
    private var extensionPageRetries = 0

    func browserPage(
        _ page: BrowserPage,
        decidePolicyFor navigationAction: BrowserNavigationAction
    ) -> BrowserNavigationActionDisposition {
        if let routed = routeToRuleSpace(navigationAction, page: page) {
            return routed
        }

        let intent = LinkOpenIntent.from(
            buttonNumber: navigationAction.buttonNumber,
            modifiers: navigationAction.modifierFlags
        )
        guard intent != .sameTab,
              let url = navigationAction.request.url,
              let tab,
              let tabManager = tab.tabManager,
              let historyManager = tab.historyManager,
              let downloadManager = tab.downloadManager
        else {
            return .allow
        }

        MainActor.assumeIsolated {
            _ = tabManager.openTab(
                url: url,
                historyManager: historyManager,
                downloadManager: downloadManager,
                focusAfterOpening: intent == .foreground,
                isPrivate: tab.isPrivate
            )
        }
        // Cancel, not `.openInNewTab`: the tab is already open, and that disposition
        // would have the page ask for a second one on the same URL.
        return .cancel
    }

    func browserPage(_ page: BrowserPage, didRequestOpenInNewTab url: URL) {
        guard let tab,
              let tabManager = tab.tabManager,
              let historyManager = tab.historyManager
        else {
            return
        }

        MainActor.assumeIsolated {
            _ = tabManager.openTab(
                url: url,
                historyManager: historyManager,
                downloadManager: tab.downloadManager,
                isPrivate: tab.isPrivate
            )
        }
    }

    /// The popup keeps the opener alive only while it is the tab's own page, so the tab
    /// is handed the page WebKit made rather than building a second one of its own.
    /// `isWebViewReady` is set here so `restoreTransientState` leaves it alone.
    func browserPage(_ page: BrowserPage, didRequestAdopt popup: BrowserPage, for url: URL?) -> Bool {
        guard let tab, let tabManager = tab.tabManager else { return false }

        return MainActor.assumeIsolated {
            guard let container = tabManager.activeContainer else { return false }
            let newTab = tabManager.addTab(
                url: url ?? URL(string: "about:blank")!,
                container: container,
                historyManager: tab.historyManager,
                downloadManager: tab.downloadManager,
                isPrivate: tab.isPrivate
            )
            // WebKit built the popup on the opener's data store, so the adopted tab
            // records the opener's container rather than the space default.
            newTab.browsingContainer = tab.browsingContainer
            newTab.browserPage = popup
            newTab.setupBrowserPageDelegate(for: popup)
            newTab.syncBackgroundColorFromHex()
            newTab.isWebViewReady = true
            return true
        }
    }

    func browserPage(_ page: BrowserPage, didUpdateNavigation event: BrowserNavigationEvent) {
        guard let tab else { return }
        flushPendingHeaderColor(page)

        switch event.phase {
        case .started:
            progressResetWorkItem?.cancel()
            // The page that raised them is going away, and WebKit hangs a page on a
            // reply that never comes, so anything outstanding is refused first.
            MainActor.assumeIsolated {
                SitePermissionCoordinator.shared.cancelRequests(forTab: tab.id)
            }
            tab.clearNavigationError()
            tab.colorUpdated = false
            passwordCoordinator?.clearAutofillState()
            tab.isLoading = event.isLoading
            tab.loadingProgress = event.progress
            if let url = event.url {
                tab.updateURL(url)
            }

        case .committed:
            tab.isLoading = event.isLoading
            tab.loadingProgress = event.progress
            if let title = event.title, !title.isEmpty {
                tab.title = title
                MainActor.assumeIsolated {
                    mediaController?.syncTitleForTab(tab.id, newTitle: title)
                }
            }

        case .finished:
            tab.isLoading = event.isLoading
            tab.loadingProgress = event.progress
            if let title = event.title, !title.isEmpty {
                tab.title = title
                MainActor.assumeIsolated {
                    mediaController?.syncTitleForTab(tab.id, newTitle: title)
                }
            } else if (event.url ?? tab.url).isFileURL {
                // A PDF or a plain-text file reports no title, which left the sidebar
                // row blank. The file name is what the user opened, so show that.
                tab.title = (event.url ?? tab.url).lastPathComponent
            }
            if let url = event.url {
                tab.updateURL(url)
                // Unconditional: `setFavicon` no-ops when the domain already matches, and
                // gating on `favicon == nil` left the previous site's icon on the tab
                // after a cross-domain navigation.
                tab.setFavicon()
                recordHistory(for: tab)
                tab.updateHeaderColor()
            }
            // A tab coming back from hibernation reloads from the top; put it back
            // where the user left it.
            tab.restoreScrollOffsetIfNeeded()
            // The one moment the back/forward list is settled.
            tab.captureSession()

            let workItem = DispatchWorkItem { [weak tab] in
                tab?.loadingProgress = 0
            }
            progressResetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
        }

        MainActor.assumeIsolated {
            // Per-site zoom rides on every phase that names a URL, not just the finished
            // one: `pageZoom` belongs to the web view rather than the document, so a tab
            // leaving a zoomed site carries that zoom to the next one until it is reset,
            // and doing it at `.started` means the first frame is already the right size.
            SiteZoomController.apply(to: page, url: event.url ?? page.currentURL)
            ExtensionManager.shared.tabNavigationDidChange(tab)
        }
    }

    func browserPage(_ page: BrowserPage, didFailNavigationWith error: Error, failingURL: URL?) {
        // Cancellations are not failures: a superseding navigation, a download, a
        // blocked subresource or a policy redirect all end the previous load with
        // NSURLErrorCancelled or WebKit's "frame load interrupted". Showing the error
        // page for those replaces a rendered page with a blank one.
        let nsError = error as NSError
        let isCancellation = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        guard !isCancellation else { return }
        guard !retriedExtensionPage(failingURL ?? tab?.url, page: page) else { return }
        tab?.setNavigationError(error, for: failingURL)
    }

    /// True when the failed load was an extension's own page and the load is being
    /// tried again rather than reported.
    ///
    /// A tab restored onto `webkit-extension://` beats the extension it names: the
    /// folder scan, the manifest parse and WebKit's own load all start from the first
    /// page Aura builds and finish long after that page has begun loading. Until they
    /// do, nothing answers for the address and WebKit fails it — which put Aura's
    /// error page on a restored uBlock Origin dashboard on every launch. Retrying
    /// only while extensions are still coming up keeps an address that will never
    /// resolve (an extension since removed) reporting straight away.
    private func retriedExtensionPage(_ url: URL?, page: BrowserPage) -> Bool {
        // Cheapest test first: every ordinary page that fails comes through here too,
        // and none of them has any business asking the extension manager anything.
        guard let url, url.scheme?.lowercased() == ExtensionOrigin.scheme else { return false }
        let loading = MainActor.assumeIsolated { ExtensionManager.shared.isLoadingExtensions }
        guard Self.shouldRetryExtensionPage(url, attempts: extensionPageRetries, extensionsAreLoading: loading) else {
            return false
        }

        extensionPageRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.extensionPageRetryDelay) { [weak page] in
            page?.load(URLRequest(url: url))
        }
        return true
    }

    /// Half a second between tries, twelve at most: six seconds is longer than a cold
    /// launch spends scanning and loading, and short enough that a page which is never
    /// coming still reports itself while the user is looking at the tab.
    static let extensionPageRetryDelay: TimeInterval = 0.5

    /// The rule `retriedExtensionPage` applies, kept separate so it can be read and
    /// tested without a web view: only an extension's own page, only while the
    /// extensions are still loading, and only so many times.
    static func shouldRetryExtensionPage(_ url: URL, attempts: Int, extensionsAreLoading: Bool) -> Bool {
        guard url.scheme?.lowercased() == ExtensionOrigin.scheme else { return false }
        return extensionsAreLoading && attempts < 12
    }

    func browserPage(_ page: BrowserPage, didReceiveScriptMessage message: BrowserScriptMessage) {
        guard let tab else { return }

        switch message.name {
        case "listener":
            flushPendingHeaderColor(page)
            handleURLUpdateMessage(message.body, for: tab)
        case "linkHover":
            let hovered = (message.body as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            tab.hoveredLinkURL = hovered.isEmpty ? nil : hovered
        case "mediaEvent":
            handleMediaEventMessage(message.body, for: tab)
        case "passwordManager":
            if let body = message.body as? String {
                passwordCoordinator?.handleMessage(body, pageURL: page.currentURL)
            }
        default:
            break
        }
    }

    /// Never `.prompt`: that hands the question back to WebKit, which puts its own raw
    /// dialog up and remembers nothing. The coordinator answers from the site's stored
    /// grants when it has one and queues Aura's own prompt when it does not.
    func browserPage(
        _ page: BrowserPage,
        requestPermission permission: BrowserPermissionKind,
        origin: URL?,
        decisionHandler: @escaping (BrowserPermissionDecision) -> Void
    ) {
        guard let tab else {
            decisionHandler(.deny)
            return
        }
        MainActor.assumeIsolated {
            SitePermissionCoordinator.shared.request(
                kind: permission,
                origin: origin ?? page.currentURL,
                tabID: tab.id,
                isPrivate: tab.isPrivate,
                decide: decisionHandler
            )
        }
    }

    func browserPage(
        _ page: BrowserPage,
        runOpenPanelWith options: BrowserOpenPanelOptions,
        completion: @escaping ([URL]?) -> Void
    ) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = options.allowsDirectories
        openPanel.allowsMultipleSelection = options.allowsMultipleSelection
        openPanel.begin { result in
            completion(result == .OK ? openPanel.urls : nil)
        }
    }

    /// `runModal` here spins a nested modal run loop on the main thread, which stalls
    /// every other window and, worse, any web process parked in a synchronous
    /// injected-bundle ask, for as long as the dialog is up. A sheet keeps the run loop
    /// turning, so any visible window will do as a host: a dialog on the wrong window
    /// beats freezing all of them.
    private func present(_ alert: NSAlert, on page: BrowserPage, respond: @escaping (Bool) -> Void) {
        let host = page.window
            ?? NSApp.keyWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey && $0.attachedSheet == nil }
        guard let host else {
            // Last resort: the page is windowless (an off-screen or detached web view)
            // and there is nothing on screen to attach to. This blocks the whole UI
            // thread until the dialog is dismissed.
            respond(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: host) { response in
            respond(response == .alertFirstButtonReturn)
        }
    }

    func browserPage(_ page: BrowserPage, runJavaScriptAlert message: String, completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Alert"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        present(alert, on: page) { _ in completion() }
    }

    func browserPage(_ page: BrowserPage, runJavaScriptConfirm message: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Confirm"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, on: page, respond: completion)
    }

    func browserPage(
        _ page: BrowserPage,
        runJavaScriptPrompt prompt: String,
        defaultText: String?,
        completion: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Prompt"
        alert.informativeText = prompt
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = defaultText ?? ""
        alert.accessoryView = textField

        present(alert, on: page) { accepted in
            completion(accepted ? textField.stringValue : nil)
        }
    }

    func browserPage(
        _ page: BrowserPage,
        didRequestContextMenu info: BrowserContextMenuInfo,
        at location: CGPoint,
        inspectElement: (() -> Void)?
    ) {
        guard let tab else { return }
        MainActor.assumeIsolated {
            let menu = PageContextMenu(tab: tab, page: page, info: info, inspectElement: inspectElement)
            AuraMenuController.shared.present(menu.items(), at: location, in: page.window)
        }
    }

    func browserPage(_ page: BrowserPage, didStartDownload download: BrowserDownloadTask) {
        MainActor.assumeIsolated {
            tab?.downloadManager?.handleDownload(download)

            guard page.isDownloadNavigation, let tab else { return }

            if page.lastCommittedURL != nil {
                tab.goBack()
            } else if let tabManager = tab.tabManager {
                tabManager.closeTab(tab: tab)
            }
        }
    }

    /// Returns false when the page cannot produce a snapshot yet, so the caller can retry
    /// instead of the tab polling for one.
    @discardableResult
    func takeSnapshotAfterLoad(_ page: BrowserPage) -> Bool {
        let bounds = page.contentView.bounds
        guard !page.isLoading, bounds.width > 0 else { return false }

        let window = page.contentView.window
        guard HeaderColorSnapshot.shouldSnapshot(
            windowIsKey: window?.isKeyWindow ?? false,
            isVisibleTab: window != nil
        ) else {
            // Handled, so the caller stops retrying; the colour is taken when the tab
            // is next in front.
            pendingHeaderColor = true
            return true
        }
        pendingHeaderColor = false

        page
            .takeSnapshot(configuration: HeaderColorSnapshot
                .configuration(for: bounds.size)) { [weak self] image, error in
                    guard let self, let image, error == nil else { return }
                    guard let full = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    let strip = HeaderColorSnapshot.stripRect(
                        imageSize: CGSize(width: full.width, height: full.height),
                        viewSize: bounds.size
                    )
                    let cgImage = full.cropping(to: strip) ?? full

                    DispatchQueue.main.async {
                        let color = Self.extractDominantColor(from: cgImage) ?? .black
                        self.tab?.updateBackgroundColor(Color(nsColor: color))
                        self.tab?.colorUpdated = true
                    }
            }

        return true
    }

    /// Retakes a colour that was skipped while the tab was out of sight.
    private func flushPendingHeaderColor(_ page: BrowserPage) {
        guard pendingHeaderColor else { return }
        takeSnapshotAfterLoad(page)
    }

    /// Records a visit only when the tab moved to a different URL. A title-only report
    /// refreshes the existing entry instead of counting a second visit.
    private func recordHistory(for tab: Tab) {
        guard let historyManager = tab.historyManager else { return }
        let change = historyGate.change(url: tab.url, title: tab.title, favicon: tab.favicon)
        guard change != .none else { return }
        let countsAsVisit = change == .visit
        let (title, url, favicon, localFile, container) =
            (tab.title, tab.url, tab.favicon, tab.faviconLocalFile, tab.container)
        Task { @MainActor in
            historyManager.record(
                title: title,
                url: url,
                faviconURL: favicon,
                faviconLocalFile: localFile,
                container: container,
                countsAsVisit: countsAsVisit
            )
        }
    }

    private func handleURLUpdateMessage(_ body: Any?, for tab: Tab) {
        guard let jsonString = body as? String,
              let jsonData = jsonString.data(using: .utf8),
              let update = try? JSONDecoder().decode(URLUpdate.self, from: jsonData)
        else {
            return
        }

        let oldTitle = tab.title
        tab.title = update.title
        if let href = URL(string: update.href) {
            tab.updateURL(href)
        }
        tab.setFavicon()
        recordHistory(for: tab)

        if oldTitle != update.title, !update.title.isEmpty {
            MainActor.assumeIsolated {
                mediaController?.syncTitleForTab(tab.id, newTitle: update.title)
            }
        }
    }

    private func handleMediaEventMessage(_ body: Any?, for tab: Tab) {
        guard let payloadBody = body as? String,
              let data = payloadBody.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MediaEventPayload.self, from: data)
        else {
            return
        }

        MainActor.assumeIsolated {
            mediaController?.receive(event: payload, from: tab)
        }
    }

    /// One 1x1 scratch bitmap for every average taken in the app. Building a `CGContext`
    /// per navigation is allocation for nothing. Main thread only, which is where the
    /// snapshot completion is hopped onto before it draws.
    private static let averagingContext = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )

    private static func extractDominantColor(from cgImage: CGImage) -> NSColor? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard cgImage.width > 0, cgImage.height > 0 else { return nil }
        guard let context = averagingContext else { return nil }

        // The pixel is reused, so last navigation's colour has to go before a partly
        // transparent page blends over it.
        let pixel = CGRect(x: 0, y: 0, width: 1, height: 1)
        context.clear(pixel)
        context.draw(cgImage, in: pixel)
        guard let data = context.data else { return nil }

        let pixels = data.assumingMemoryBound(to: UInt8.self)
        return NSColor(
            red: CGFloat(pixels[0]) / 255.0,
            green: CGFloat(pixels[1]) / 255.0,
            blue: CGFloat(pixels[2]) / 255.0,
            alpha: CGFloat(pixels[3]) / 255.0
        )
    }
}

// MARK: - Site-to-space rules

private extension TabBrowserPageDelegate {
    /// Firefox-style containers: a site pinned to another space is opened there instead.
    /// Returns nil when the navigation is none of this delegate's business.
    func routeToRuleSpace(
        _ navigationAction: BrowserNavigationAction,
        page: BrowserPage
    ) -> BrowserNavigationActionDisposition? {
        guard navigationAction.isMainFrame,
              let url = navigationAction.request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let tab,
              // Private windows have no spaces to route between.
              !tab.isPrivate,
              let tabManager = tab.tabManager,
              let historyManager = tab.historyManager
        else {
            return nil
        }

        return MainActor.assumeIsolated { () -> BrowserNavigationActionDisposition? in
            guard let targetID = SiteSpaceRuleService.shared.containerID(for: url),
                  targetID != tab.container.id,
                  let space = tabManager.fetchContainers().first(where: { $0.id == targetID })
            else {
                return nil
            }

            tabManager.openTab(
                url: url,
                in: space,
                historyManager: historyManager,
                downloadManager: tab.downloadManager,
                isPrivate: tab.isPrivate,
                reusingHost: true
            )
            // A tab opened only to follow this link has nothing to fall back to, so it goes
            // rather than sitting there blank.
            if page.lastCommittedURL == nil {
                tabManager.closeTab(tab: tab)
            }
            return .cancel
        }
    }
}
