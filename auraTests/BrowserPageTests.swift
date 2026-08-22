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

    // MARK: - Helpers

    @MainActor
    private static func makePage(
        allowsPopups: Bool = false,
        delegate: BrowserPageDelegate? = nil
    ) -> BrowserPage {
        // Private: no persistent data store, and no extension controller attached, so
        // building a page here cannot install the bundled extensions.
        let profile = BrowserEngineProfile(identifier: UUID(), isPrivate: true)
        var configuration = BrowserPageConfiguration.oraDefault(
            userScripts: [],
            privacySettings: SpacePrivacySettings(blockThirdPartyTrackers: false, blockFingerprinting: false)
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
