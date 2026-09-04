import AppKit
import Foundation
import Testing
import WebKit

@testable import Aura

/// The engine-level fixes: the download delegate selector, the WebContent crash backoff,
/// find in page on WebKit's own search, and `window.open` keeping its opener.
///
/// The last two drive a real `BrowserPage`, so they build one on a private profile:
/// that skips the extension controller (and with it the bundled-extension install) and
/// leaves no website data behind.
@Suite(.serialized)
struct BrowserPageTests {
    // MARK: - Downloads

    /// `download(_:didFailWithError:)` is not a `WKDownloadDelegate` method. Implementing
    /// it meant WebKit never reported a failure: the download stayed "downloading" and
    /// its 10 Hz progress timer ran until the app quit. The `#selector` below is the
    /// compile-time half of the check — it names the protocol method, so the file stops
    /// building if the signature drifts again.
    @Test
    func downloadTaskImplementsWebKitsFailureSelector() {
        let failure = #selector(WKDownloadDelegate.download(_:didFailWithError:resumeData:))
        #expect(BrowserDownloadTask.instancesRespond(to: failure))

        // The rest of the delegate, so a future refactor cannot quietly drop one.
        #expect(BrowserDownloadTask.instancesRespond(
            to: #selector(WKDownloadDelegate.download(_:decideDestinationUsing:suggestedFilename:completionHandler:))
        ))
        #expect(BrowserDownloadTask.instancesRespond(to: #selector(WKDownloadDelegate.downloadDidFinish(_:))))
    }

    // MARK: - WebContent crashes

    @Test
    func crashReloadsBackOffAndThenGiveUp() {
        #expect(BrowserPage.crashReloadDelay(forCrashCount: 1) == 2)
        #expect(BrowserPage.crashReloadDelay(forCrashCount: 2) == 4)
        #expect(BrowserPage.crashReloadDelay(forCrashCount: 3) == 6)
        #expect(BrowserPage.crashReloadDelay(forCrashCount: 4) == 8)
        // Past the burst limit the page stops reloading rather than feeding a crash loop.
        #expect(BrowserPage.crashReloadDelay(forCrashCount: 5) == nil)
        #expect(BrowserPage.crashReloadDelay(forCrashCount: 99) == nil)
    }

    // MARK: - Extension pages

    /// A tab restored onto an extension's own page asks for it before the extension
    /// has loaded, and WebKit fails that. The address is good, so it is tried again
    /// rather than reported — but only while there is still an extension coming up,
    /// and not forever.
    @Test
    func extensionPagesWaitForTheirExtensionButNotIndefinitely() throws {
        let page = try #require(URL(string: "webkit-extension://f47ac10b-58cc-4372-a567-0e02b2c3d479/dashboard.html"))
        #expect(TabBrowserPageDelegate.shouldRetryExtensionPage(page, attempts: 0, extensionsAreLoading: true))
        #expect(TabBrowserPageDelegate.shouldRetryExtensionPage(page, attempts: 11, extensionsAreLoading: true))
        // An extension that is never coming: report the failure now.
        #expect(!TabBrowserPageDelegate.shouldRetryExtensionPage(page, attempts: 0, extensionsAreLoading: false))
        #expect(!TabBrowserPageDelegate.shouldRetryExtensionPage(page, attempts: 12, extensionsAreLoading: true))

        // Ordinary pages report the first failure, whatever the extensions are doing.
        let web = try #require(URL(string: "https://example.com/"))
        #expect(!TabBrowserPageDelegate.shouldRetryExtensionPage(web, attempts: 0, extensionsAreLoading: true))
    }

    /// WebKit serves an extension's own page only to a web view built for that extension,
    /// and such a web view serves nothing else, so a main-frame navigation across that
    /// line swaps web views. Unless the extension is not up yet: then the load is left to
    /// fail and be retried, or every launch would rebuild the restored tab in a loop.
    @Test
    func extensionPagesAndTheWebNeverShareAWebView() throws {
        let dashboard = try #require(
            URL(string: "webkit-extension://f47ac10b-58cc-4372-a567-0e02b2c3d479/dashboard.html")
        )
        let other = try #require(URL(string: "webkit-extension://0a1b2c3d-58cc-4372-a567-0e02b2c3d479/popup.html"))
        let web = try #require(URL(string: "https://example.com/"))
        let host = try #require(dashboard.host)

        // An ordinary web view hands over for an extension page, once one can host it.
        #expect(TabBrowserPageDelegate.needsRehost(hostedExtensionHost: nil, target: dashboard, canHost: true))
        #expect(!TabBrowserPageDelegate.needsRehost(hostedExtensionHost: nil, target: dashboard, canHost: false))
        #expect(!TabBrowserPageDelegate.needsRehost(hostedExtensionHost: nil, target: web, canHost: false))

        // An extension's web view keeps its own pages and hands over for everything else.
        #expect(!TabBrowserPageDelegate.needsRehost(hostedExtensionHost: host, target: dashboard, canHost: true))
        #expect(TabBrowserPageDelegate.needsRehost(hostedExtensionHost: host, target: web, canHost: false))
        #expect(TabBrowserPageDelegate.needsRehost(hostedExtensionHost: host, target: other, canHost: true))
        #expect(!TabBrowserPageDelegate.needsRehost(hostedExtensionHost: host, target: other, canHost: false))
    }

    // MARK: - Find in page

    /// A term that appears exactly once, searched twice. The second search starts past
    /// the only match, so it can only succeed by wrapping to the top of the document.
    @MainActor
    @Test
    func nativeFindWrapsPastTheLastMatch() async throws {
        let server = try LocalHTTPServer(
            html: "<!doctype html><meta charset=\"utf-8\"><body><p>alpha unrepeated omega</p></body>"
        )
        let port = try await server.start()
        defer { server.stop() }

        let page = Self.makePage()
        defer { page.teardown() }
        let hosted = Self.host(page)
        defer { hosted.close() }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/index.html"))
        page.load(URLRequest(url: url))
        #expect(await Self.waitForDocument(url, in: page), "fixture page never finished loading")

        let controller = FindController(page: page)
        #expect(await Self.find("unrepeated", with: controller) == true)
        #expect(await Self.find("unrepeated", with: controller) == true, "the second pass has to wrap")
        #expect(await Self.find("UNREPEATED", with: controller) == true, "the search is case-insensitive")
        #expect(await Self.find("nothing-here-at-all", with: controller) == false)
    }

    // MARK: - window.open

    /// The popup has to be built on the configuration WebKit hands over, or its
    /// `window.opener` comes back null and every OAuth flow that posts its token back to
    /// the opener breaks. Gated like the other networked WebKit checks: pass
    /// `TEST_RUNNER_AURA_BUNDLE=1`.
    @MainActor
    @Test(.enabled(if: WebBundleTests.isEnabled))
    func anAdoptedPopupKeepsItsOpener() async throws {
        // The popup gets the same document, and the guard keeps it from opening one of
        // its own: having an opener is exactly what the test is asserting.
        let server = try LocalHTTPServer(html: """
        <!doctype html><meta charset="utf-8"><body><script>
        if (!window.opener) { window.open('/popup.html', '_blank'); }
        </script></body>
        """)
        let port = try await server.start()
        defer { server.stop() }

        let adopter = PopupAdoptingDelegate()
        let page = Self.makePage(allowsPopups: true, delegate: adopter)
        defer { page.teardown() }
        let hosted = Self.host(page)
        defer { hosted.close() }

        page.load(URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/index.html"))))

        let popup = try #require(
            await Self.poll(timeout: 20) { adopter.adopted },
            "the page never asked the delegate to adopt a popup"
        )
        defer { popup.teardown() }

        let opener = await Self.poll(timeout: 20) { () -> String? in
            let value = await Self.evaluate("window.opener ? 'yes' : 'no'", in: popup) as? String
            return value == "pending" ? nil : value
        }
        #expect(opener == "yes", "window.opener was severed, so the popup cannot talk back")
    }

    // MARK: - Global Privacy Control

    /// The header rides on a navigation that is cancelled and re-issued. Two things can
    /// go wrong that no pure test sees: WebKit could drop the header from the re-issued
    /// request, which would cancel every load forever, and the user script could fail to
    /// define the page-side flag. A real load against a local server settles both.
    @MainActor
    @Test
    func aPageSendsTheGlobalPrivacyControlSignalOnce() async throws {
        let server = try LocalHTTPServer(html: "<!doctype html><meta charset=\"utf-8\"><body>gpc</body>")
        let port = try await server.start()
        defer { server.stop() }

        let recorder = PolicyRecordingDelegate()
        let page = Self.makePage(globalPrivacyControl: true, delegate: recorder)
        defer { page.teardown() }
        let hosted = Self.host(page)
        defer { hosted.close() }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/index.html"))
        page.load(URLRequest(url: url))
        #expect(await Self.waitForDocument(url, in: page), "fixture page never finished loading")

        // The server saw the header, and saw the document once: the bare navigation was
        // cancelled before it reached the network.
        #expect(server.servedHeaders["/index.html"]?["sec-gpc"] == "1")
        #expect(server.servedPaths.filter { $0 == "/index.html" }.count == 1)
        // The delegate was asked twice, bare and then with the header, and no more.
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "Sec-GPC") == nil)
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "Sec-GPC") == "1")
        #expect(await Self.evaluate("navigator.globalPrivacyControl === true", in: page) as? Bool == true)

        // Off: one decision, no header, no flag.
        let quiet = PolicyRecordingDelegate()
        let plainPage = Self.makePage(globalPrivacyControl: false, delegate: quiet)
        defer { plainPage.teardown() }
        let plainHost = Self.host(plainPage)
        defer { plainHost.close() }
        let plain = try #require(URL(string: "http://127.0.0.1:\(port)/plain.html"))
        plainPage.load(URLRequest(url: plain))
        #expect(await Self.waitForDocument(plain, in: plainPage), "plain page never finished loading")
        #expect(server.servedHeaders["/plain.html"]?["sec-gpc"] == nil)
        #expect(quiet.requests.count == 1)
        #expect(await Self.evaluate("navigator.globalPrivacyControl === true", in: plainPage) as? Bool == false)
    }

    // MARK: - Link clicks

    /// Middle-clicking or command-clicking a link has to leave the current page where it
    /// is. The bug this pins down was the command path opening the tab and then returning
    /// `.openInNewTab`, which had the page open a second tab on the same URL, in front.
    @Test
    func middleAndCommandClickOpenLinksBehindThePage() {
        #expect(LinkOpenIntent.from(buttonNumber: 0, modifiers: []) == .sameTab)
        #expect(LinkOpenIntent.from(buttonNumber: 2, modifiers: []) == .background)
        #expect(LinkOpenIntent.from(buttonNumber: 0, modifiers: .command) == .background)
        // Shift on top of either is the "and take me there" variant.
        #expect(LinkOpenIntent.from(buttonNumber: 2, modifiers: .shift) == .foreground)
        #expect(LinkOpenIntent.from(buttonNumber: 0, modifiers: [.command, .shift]) == .foreground)
        // Shift on its own is a new window in other browsers, never a background tab.
        #expect(LinkOpenIntent.from(buttonNumber: 0, modifiers: .shift) == .sameTab)
        // The back and forward thumb buttons are not link clicks.
        #expect(LinkOpenIntent.from(buttonNumber: 3, modifiers: []) == .sameTab)
    }

    // MARK: - Helpers

    @MainActor
    private static func makePage(
        allowsPopups: Bool = false,
        globalPrivacyControl: Bool = false,
        delegate: BrowserPageDelegate? = nil
    ) -> BrowserPage {
        // Private: no persistent data store, and no extension controller attached, so
        // building a page here cannot install the bundled extensions.
        let profile = BrowserEngineProfile(identifier: UUID(), isPrivate: true)
        let privacySettings = SpacePrivacySettings(
            blockThirdPartyTrackers: false,
            blockFingerprinting: false,
            globalPrivacyControl: globalPrivacyControl
        )
        var configuration = BrowserPageConfiguration.oraDefault(
            userScripts: BrowserPrivacyService.privacyScripts(for: privacySettings),
            privacySettings: privacySettings
        )
        if allowsPopups {
            configuration = BrowserPageConfiguration(
                userAgent: configuration.userAgent,
                allowsPictureInPicture: false,
                allowsJavaScript: true,
                allowsJavaScriptWindowsAutomatically: true,
                allowsAirPlayForMediaPlayback: false,
                allowsInspectableDebugging: true,
                allowsBackForwardNavigationGestures: false,
                mediaPlaybackRequiresUserAction: false,
                scriptMessageNames: configuration.scriptMessageNames,
                userScripts: [],
                privacySettings: configuration.privacySettings
            )
        }
        return BrowserPage(profile: profile, configuration: configuration, delegate: delegate)
    }

    /// WebKit throttles a web view that is in no window at all, which turns every load
    /// in here into a timeout.
    @MainActor
    private static func host(_ page: BrowserPage) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        page.contentView.frame = frame
        window.contentView = page.contentView
        window.makeKeyAndOrderFront(nil)
        return window
    }

    @MainActor
    private static func evaluate(_ script: String, in page: BrowserPage) async -> Any? {
        await withCheckedContinuation { continuation in
            page.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result)
            }
        }
    }

    /// Waits for *that* document, not the one the web view starts on: a fresh WKWebView
    /// already sits on about:blank with `readyState` at "complete", so polling readyState
    /// alone returns before the load has begun.
    @MainActor
    private static func waitForDocument(
        _ url: URL,
        in page: BrowserPage,
        timeout: TimeInterval = 20
    ) async -> Bool {
        await poll(timeout: timeout) { () -> Bool? in
            guard await evaluate("location.href", in: page) as? String == url.absoluteString,
                  await evaluate("document.readyState", in: page) as? String == "complete"
            else { return nil }
            return true
        } ?? false
    }

    @MainActor
    private static func poll<Value>(
        timeout: TimeInterval,
        _ probe: @MainActor () async -> Value?
    ) async -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = await probe() { return value }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    private static func find(_ term: String, with controller: FindController) async -> Bool {
        await withCheckedContinuation { continuation in
            controller.find(term) { matched in
                continuation.resume(returning: matched)
            }
        }
    }
}

/// Takes the popup the page offers, exactly as `TabBrowserPageDelegate` does, minus the
/// tab it would be hosted in.
@MainActor
private final class PopupAdoptingDelegate: BrowserPageDelegate {
    private(set) var adopted: BrowserPage?
    private var window: NSWindow?

    nonisolated func browserPage(_ page: BrowserPage, didRequestAdopt popup: BrowserPage, for url: URL?) -> Bool {
        MainActor.assumeIsolated {
            adopted = popup
            let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            let hosting = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            popup.contentView.frame = frame
            hosting.contentView = popup.contentView
            hosting.orderFront(nil)
            window = hosting
            return true
        }
    }
}

/// Records every navigation the page asks about, so a test can see the cancelled bare
/// request and the re-issued one side by side.
@MainActor
private final class PolicyRecordingDelegate: BrowserPageDelegate {
    private(set) var requests: [URLRequest] = []

    nonisolated func browserPage(
        _ page: BrowserPage,
        decidePolicyFor navigationAction: BrowserNavigationAction
    ) -> BrowserNavigationActionDisposition {
        MainActor.assumeIsolated {
            requests.append(navigationAction.request)
            return .allow
        }
    }
}

/// The two decisions behind the chrome colour: what is rendered, and whether it is
/// rendered at all. Both are pure, so neither needs a web view.
struct HeaderColorSnapshotTests {
    @Test func theSnapshotIsTheWholeViewAtThumbnailWidthNeverARect() {
        let config = HeaderColorSnapshot.configuration(for: CGSize(width: 1440, height: 900))
        // A rect-scoped snapshot flashes the page; the strip is cropped from the bitmap.
        #expect(config.rect == nil)
        #expect(config.snapshotWidth == 32)
        #expect(config.afterScreenUpdates)
    }

    @Test func theStripIsCutFromTheScaledBitmap() {
        // 1440x900 view scaled to 32x20: 24pt of 900 is 2.67% of 20px, rounded up to 1px.
        let strip = HeaderColorSnapshot.stripRect(
            imageSize: CGSize(width: 32, height: 20),
            viewSize: CGSize(width: 1440, height: 900)
        )
        #expect(strip == CGRect(x: 0, y: 0, width: 32, height: 1))
        // A view shorter than the strip uses the whole bitmap.
        let whole = HeaderColorSnapshot.stripRect(
            imageSize: CGSize(width: 32, height: 2),
            viewSize: CGSize(width: 300, height: 10)
        )
        #expect(whole == CGRect(x: 0, y: 0, width: 32, height: 2))
        // Before layout the height is unknown; the whole bitmap stands in.
        let unlaidOut = HeaderColorSnapshot.stripRect(
            imageSize: CGSize(width: 32, height: 20),
            viewSize: CGSize(width: 300, height: 0)
        )
        #expect(unlaidOut.height == 20)
    }

    @Test func onlyTheVisibleTabInTheKeyWindowForcesARender() {
        #expect(HeaderColorSnapshot.shouldSnapshot(windowIsKey: true, isVisibleTab: true))
        // A background tab has no window, and a background window is behind something.
        #expect(!HeaderColorSnapshot.shouldSnapshot(windowIsKey: true, isVisibleTab: false))
        #expect(!HeaderColorSnapshot.shouldSnapshot(windowIsKey: false, isVisibleTab: true))
        #expect(!HeaderColorSnapshot.shouldSnapshot(windowIsKey: false, isVisibleTab: false))
    }
}
