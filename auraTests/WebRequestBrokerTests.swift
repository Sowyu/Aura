import Foundation
import Testing
import WebKit

@testable import Aura

// swiftlint:disable no_print_statements
// The round-trip measurement prints its number; that line is the deliverable.

/// Proves an extension's blocking `webRequest` listener cancels a request
/// before it leaves the web process, which WebKit on its own cannot do.
///
/// The WebKit half is gated the same way `WebBundleTests` is: pass
/// `TEST_RUNNER_AURA_BUNDLE=1` to xcodebuild.
@Suite(.serialized)
struct WebRequestBrokerTests {
    static var isEnabled: Bool { WebBundleTests.isEnabled }

    // MARK: - Shim patching

    @Test
    func shimPatchesBackgroundScriptsAndIsIdempotent() throws {
        let directory = try makeExtension(background: ["scripts": ["bg.js"]])
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try ExtensionShim.apply(at: directory), "first patch should rewrite the manifest")
        #expect(try ExtensionShim.apply(at: directory) == false, "second patch should be a no-op")
        #expect(ExtensionShim.isPatched(at: directory))

        let manifest = try readManifest(at: directory)
        #expect(manifest["background"]?["scripts"] as? [String]
            == ["aura-shim-manifest.js", "aura-shim.js", "bg.js"])
        #expect(manifest.permissions.contains("nativeMessaging"), "the shim's only way back is a native port")
        #expect(manifest.version == ExtensionShim.version)

        let original = directory.appendingPathComponent(ExtensionShim.originalManifestName)
        let untouched = try JSONSerialization.jsonObject(with: Data(contentsOf: original)) as? [String: Any]
        #expect(untouched?[ExtensionShim.versionKey] == nil, "the backup must be the manifest as downloaded")
        #expect(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("aura-shim.js").path),
            "the shim script has to sit inside the extension to be loadable from it"
        )
    }

    @Test
    func shimLeavesExtensionsThatNeverTouchWebRequestAlone() throws {
        let directory = try makeExtension(background: ["scripts": ["bg.js"]], permissions: ["storage", "tabs"])
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try ExtensionShim.apply(at: directory) == false)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("aura-shim.js").path))
    }

    @Test
    func shimWrapsAServiceWorkerAndABackgroundPage() throws {
        let worker = try makeExtension(background: ["service_worker": "sw.js"])
        defer { try? FileManager.default.removeItem(at: worker) }
        #expect(try ExtensionShim.apply(at: worker))
        let wrapped = try readManifest(at: worker)
        #expect(wrapped["background"]?["service_worker"] as? String == "aura-shim-worker.js")
        let wrapper = try String(contentsOf: worker.appendingPathComponent("aura-shim-worker.js"), encoding: .utf8)
        #expect(wrapper.contains("importScripts('aura-shim-manifest.js', 'aura-shim.js', 'sw.js')"))

        let paged = try makeExtension(background: ["page": "background.html"])
        defer { try? FileManager.default.removeItem(at: paged) }
        let pageURL = paged.appendingPathComponent("background.html")
        try "<html><head><script src=\"bg.js\"></script></head></html>".write(
            to: pageURL, atomically: true, encoding: .utf8
        )
        #expect(try ExtensionShim.apply(at: paged))
        let html = try String(contentsOf: pageURL, encoding: .utf8)
        let shimAt = try #require(html.range(of: "aura-shim.js"))
        let ownScriptAt = try #require(html.range(of: "bg.js"))
        #expect(shimAt.lowerBound < ownScriptAt.lowerBound, "the shim has to run before the extension does")
    }

    @Test
    func firstLaunchUnpacksTheBundledUBlockOrigin() throws {
        let profile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-profile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }

        let first = try Self.installBundledUBlock(into: profile)
        let installed = try #require(first, "the add-on has to ship inside the app")
        #expect(installed.lastPathComponent == "ublock-origin")
        let manifest = try readManifest(at: installed)
        #expect(manifest.raw["name"] as? String == "uBlock Origin")
        #expect(manifest.permissions.contains("webRequestBlocking"))

        // A second launch must not overwrite the copy the user has been running.
        let second = try Self.installBundledUBlock(into: profile)
        #expect(second == nil)
    }

    // MARK: - Filters

    @Test
    func matchPatternsFollowChromesGrammar() {
        #expect(MatchPattern("<all_urls>")?.matches("https://example.com/a") == true)
        #expect(MatchPattern("<all_urls>")?.matches("about:blank") == false)
        #expect(MatchPattern("https://*/*")?.matches("https://example.com/a") == true)
        #expect(MatchPattern("https://*/*")?.matches("http://example.com/a") == false)
        #expect(MatchPattern("*://ads.example/*")?.matches("http://ads.example/pixel.png") == true)
        #expect(MatchPattern("*://ads.example/*")?.matches("http://other.example/pixel.png") == false)
    }

    // MARK: - End to end

    /// The whole chain: an extension registers a blocking listener, the injected
    /// bundle stops inside `willSendRequestForFrame`, the host asks the
    /// extension, and the answer arrives before the request exists.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func blockingListenerCancelsBeforeTheRequestLeavesTheWebProcess() async throws {
        guard #available(macOS 15.4, *) else { return }

        // Aura's own rules must not be what blocks anything here.
        try installEmptyRules()

        let directory = try makeBlockingExtension()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try ExtensionShim.apply(at: directory))

        let engine = ExtensionEngine()

        let pool = try #require(AuraWebBundle.processPool)
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let port = try await server.start()

        let configuration = WKWebViewConfiguration()
        configuration.processPool = pool
        configuration.webExtensionController = engine.controller
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        _ = try await engine.load(directory: directory, id: "aura-webrequest-test")
        defer { engine.unload(id: "aura-webrequest-test") }

        let connected = await waitForBroker("aura-webrequest-test")
        #expect(connected, "the shim never reached the host: runtime.connectNative did not deliver a port")
        guard connected else { return }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/index.html"))
        webView.load(URLRequest(url: url))
        let state = try await settledPageState(of: webView)
        let served = server.servedPaths

        #expect(state["ad"] as? String == "error", "the listener cancelled /ads/pixel.png; got \(state["ad"] ?? "")")
        #expect(state["ok"] as? String == "load", "/ads/ok.png is not in the listener's block list")
        #expect(!served.contains("/ads/pixel.png"), "the cancelled image still reached the server: \(served)")
        #expect(served.contains("/ads/ok.png"), "the allowed image should have been served: \(served)")

        let median = try #require(
            WebRequestBroker.shared.medianLatencyMilliseconds,
            "no round trip was measured, so nothing was actually asked"
        )
        print(String(format: "BENCH webrequest-roundtrip samples=%d median_ms=%.2f",
                     WebRequestBroker.shared.latencies.count, median))
        #expect(median < WebRequestBroker.timeout * 1000, "round trip should beat the timeout")
    }

    // MARK: - uBlock Origin

    /// The bundled add-on, unpacked, shimmed and asked to block a real EasyList
    /// hit. Nothing here is a stand-in: it is uBlock Origin's own static
    /// filtering engine deciding, and the injected bundle acting on it.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func uBlockOriginBlocksAnEasyListHit() async throws {
        guard #available(macOS 15.4, *) else { return }
        try installEmptyRules()

        let directory = try unpackBundledUBlock()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try ExtensionShim.apply(at: directory), "uBlock ships a background page, which needs the shim tag")

        let engine = ExtensionEngine()
        let server = try LocalHTTPServer(html: Self.uBlockTestPage)
        defer { server.stop() }
        let port = try await server.start()

        let configuration = WKWebViewConfiguration()
        configuration.processPool = try #require(AuraWebBundle.processPool)
        configuration.webExtensionController = engine.controller
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        _ = try await engine.load(directory: directory, id: Self.uBlockID)
        defer { engine.unload(id: Self.uBlockID) }

        // uBlock compiles its filter lists before it registers anything, which
        // is seconds of work on a cold profile.
        let registered = await waitForBroker(Self.uBlockID, timeout: 90)
        #expect(registered, "uBlock never registered a blocking listener; its background page did not get that far")
        guard registered else { return }

        try? await Task.sleep(for: .seconds(5))
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/index.html"))
        webView.load(URLRequest(url: url))
        let state = try await settledPageState(of: webView)
        let served = server.servedPaths

        #expect(state["ok"] as? String == "load", "/content/logo.png is not an ad; uBlock should leave it alone")
        #expect(
            state["ad"] as? String == "error",
            "EasyList's /ads/banners/*$image should have cancelled the banner; got \(state["ad"] ?? "")"
        )
        #expect(!served.contains("/ads/banners/banner.png"), "the banner still reached the server: \(served)")

        // The old failure mode: vAPI.getURL('') threw, the background page died
        // part-way through start-up, and the popup came up blank. Anything
        // WebKit reports with a JS error name in it is that failure again;
        // missing-asset and manifest gripes are not.
        let context = try #require(engine.context(for: Self.uBlockID))
        let thrown = context.errors.filter { $0.localizedDescription.contains("Error:") }
        #expect(thrown.isEmpty, "uBlock's background page threw: \(thrown.map(\.localizedDescription))")

    }

    private static let uBlockID = "ublock-origin"

    /// `/ads/banners/*$image` is an EasyList rule old enough to be dependable,
    /// and it is generic, so it matches on the loopback host too.
    private static let uBlockTestPage = """
    <!doctype html><meta charset="utf-8"><body>
    <img id="ok" src="/content/logo.png" onload="window.__okState='load'" onerror="window.__okState='error'">
    <img id="ad" src="/ads/banners/banner.png"
         onload="window.__adState='load'" onerror="window.__adState='error'">
    <script src="/app.js" onload="window.__scriptState='load'" onerror="window.__scriptState='error'"></script>
    <script>
    fetch("/api/data.json")
        .then(function () { window.__fetchState = "load"; })
        .catch(function () { window.__fetchState = "error"; });
    </script>
    </body>
    """

    private func unpackBundledUBlock() throws -> URL {
        let profile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-ublock-\(UUID().uuidString)", isDirectory: true)
        let installed = try Self.installBundledUBlock(into: profile)
        return try #require(installed, "the add-on has to ship inside the app; nothing downloads at test time")
    }

    /// The same call first launch makes, minus the "have we done this" marker.
    static func installBundledUBlock(into profile: URL) throws -> URL? {
        guard let archive = BundledExtensions.uBlockArchiveURL else { return nil }
        return try BundledExtensions.unpack(archive, named: BundledExtensions.uBlockFolderName, into: profile)
    }

    // MARK: - Helpers

    @available(macOS 15.4, *)
    @MainActor
    private func waitForBroker(_ extensionID: String, timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if WebRequestBroker.shared.hasBlockingListener(for: extensionID) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func installEmptyRules() throws {
        _ = AuraWebBundle.install()
        let url = try #require(AuraWebBundle.rulesFileURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try NativeBlockingRuleSet.make(fromFilterLines: [])
            .jsonData(revision: UUID().uuidString)
            .write(to: url, options: .atomic)
    }

    private func makeExtension(
        background: [String: Any],
        permissions: [String] = ["webRequest", "webRequestBlocking", "tabs", "<all_urls>"]
    ) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-shim-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 2,
            "name": "Aura webRequest fixture",
            "version": "1.0",
            "permissions": permissions,
            "background": background,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }

    /// An extension whose only job is to cancel two known paths, so a blocked
    /// request can only have been blocked by its listener.
    private func makeBlockingExtension() throws -> URL {
        let directory = try makeExtension(background: ["scripts": ["bg.js"]])
        let script = """
        const blocked = ['/ads/pixel.png', '/ads/beacon.json'];
        browser.webRequest.onBeforeRequest.addListener(
            details => ({ cancel: blocked.some(path => details.url.includes(path)) }),
            { urls: ['<all_urls>'] },
            ['blocking']
        );
        """
        try script.write(to: directory.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8)
        return directory
    }

    private struct Manifest {
        let raw: [String: Any]
        var permissions: [String] { raw["permissions"] as? [String] ?? [] }
        var version: Int? { raw[ExtensionShim.versionKey] as? Int }
        subscript(key: String) -> [String: Any]? { raw[key] as? [String: Any] }
    }

    private func readManifest(at directory: URL) throws -> Manifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Manifest(raw: raw)
    }
}

// swiftlint:enable no_print_statements
