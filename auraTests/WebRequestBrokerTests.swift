import AppKit
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

    /// The blocker Aura ships has to be in the app bundle and has to be a
    /// declarativeNetRequest blocker: that is the API WebKit implements itself, and
    /// the only reason blocking works here at all. Swapping in an archive without
    /// it would ship a browser that quietly blocks nothing.
    @Test
    func firstLaunchUnpacksTheBundledBlocker() throws {
        let profile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-profile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }

        #expect(BundledExtensions.archiveURL != nil, "the .xpi has to be inside the app bundle")
        let first = try Self.installBundledUBlock(into: profile)
        let installed = try #require(first, "the add-on has to ship inside the app")
        #expect(installed.lastPathComponent == BundledExtensions.folderID)

        let manifest = try readManifest(at: installed)
        #expect(manifest.raw["manifest_version"] as? Int == 3)
        #expect(manifest.permissions.contains("declarativeNetRequest"))
        #expect(!manifest.permissions.contains("webRequestBlocking"), "the bundled blocker must not need the bundle")
        #expect(ExtensionCompatibility.evaluate(permissions: manifest.permissions) == .supported)

        // Rule sets are what it actually blocks with, and at least one has to ship enabled.
        let dnr = manifest.raw["declarative_net_request"] as? [String: Any]
        let rulesets = (dnr?["rule_resources"] as? [[String: Any]]) ?? []
        #expect(rulesets.contains { $0["enabled"] as? Bool == true })

        let gecko = (manifest.raw["browser_specific_settings"] as? [String: Any])?["gecko"] as? [String: Any]
        #expect(gecko?["id"] as? String == BundledExtensions.geckoID, "pre-consent matches on this id")

        // A second launch must not overwrite the copy the user has been running.
        let second = try Self.installBundledUBlock(into: profile)
        #expect(second == nil)
    }

    /// An add-on update replaces the folder wholesale, so the copy that lands is
    /// the one the author shipped and the shim has to go back in front of it.
    /// The failure this pins down is the opposite one: a second patch stacking
    /// another pair of script tags, or the pristine-manifest backup being
    /// overwritten with an already-patched copy.
    @Test
    func anUpdatedAddOnIsRepatchedExactlyOnce() throws {
        let profile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: profile) }

        let installed = try #require(try Self.installBundledUBlock(into: profile))
        #expect(try ExtensionShim.apply(at: installed))
        #expect(ExtensionShim.isPatched(at: installed))

        // What an update does: the old folder goes, the newly downloaded one
        // takes its place under the same name.
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-update-new-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let fresh = try #require(try Self.installBundledUBlock(into: staging))
        try FileManager.default.removeItem(at: installed)
        try FileManager.default.moveItem(at: fresh, to: installed)

        #expect(!ExtensionShim.isPatched(at: installed), "a freshly downloaded copy has never been patched")
        #expect(try ExtensionShim.apply(at: installed), "an update has to be patched again")

        let popup = try String(
            contentsOf: installed.appendingPathComponent("dashboard.html"), encoding: .utf8
        )
        #expect(popup.components(separatedBy: "/aura-shim.js").count == 2, "exactly one shim tag after an update")

        let backup = installed.appendingPathComponent(ExtensionShim.originalManifestName)
        let original = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any]
        )
        #expect(original[ExtensionShim.versionKey] == nil, "the backup has to be the manifest as downloaded")
        #expect(original["name"] as? String == "uBO Lite")
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
        // A leading `*` is the scheme slot, not "anything at all". Left as `.*`
        // it matched any URL that mentioned the pattern anywhere in a query.
        #expect(
            MatchPattern("*://ads.example/*")?.matches("https://evil.test/?u=http://ads.example/x") == false
        )
    }

    // MARK: - End to end

    /// The whole chain: an extension registers a blocking listener, the injected
    /// bundle stops inside `willSendRequestForFrame`, the host asks the
    /// extension, and the answer arrives before the request exists.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func blockingListenerCancelsBeforeTheRequestLeavesTheWebProcess() async throws {
        guard #available(macOS 15.4, *) else { return }

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

    /// Every resource kind a listener can filter on, checked against a real
    /// WebKit load rather than against what the classifier is assumed to see.
    ///
    /// The extension cancels a request only when `details.type` equals the
    /// `want=` parameter baked into its URL, so a path the server never saw was
    /// classified correctly and a path it did see was not. Two controls carry
    /// the wrong `want=` and must come through.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func everyResourceKindReachesTheListenerAsTheRightType() async throws {
        guard #available(macOS 15.4, *) else { return }

        let directory = try makeExtension(background: ["scripts": ["bg.js"]])
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.typeProbeBackground.write(
            to: directory.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8
        )
        #expect(try ExtensionShim.apply(at: directory))

        let engine = ExtensionEngine()
        let server = try LocalHTTPServer(html: Self.typeProbePage)
        defer { server.stop() }
        let port = try await server.start()

        let webView = try loopbackWebView(engine: engine)
        defer { webView.window?.close() }

        let id = "aura-type-probe"
        _ = try await engine.load(directory: directory, id: id)
        defer { engine.unload(id: id) }
        let ready = await waitForBroker(id)
        #expect(ready, "the probe extension never registered its listener")
        guard ready else { return }

        webView.load(URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/index.html"))))
        // The page fires everything it is going to fire in one go; wait until the
        // server has been quiet for a beat rather than for a flag per resource.
        let served = await settledPaths(of: server)

        // Reported, not asserted: the classifier reads `Accept`, and this is the
        // only place the header WebKit really sends can be seen.
        for (path, fields) in server.servedHeaders.sorted(by: { $0.key < $1.key }) where path.contains("/probe/") {
            print("PROBE \(path) accept=\(fields["accept"] ?? "-") sec-fetch-dest=\(fields["sec-fetch-dest"] ?? "-")")
        }

        let cancelled = { (path: String) in !served.contains { $0.hasPrefix(path) } }
        #expect(cancelled("/probe/image?"), "an <img> should classify as image; served \(served)")
        #expect(cancelled("/probe/script.js?"), "a <script src> should classify as script")
        #expect(cancelled("/probe/style.css?"), "a <link rel=stylesheet> should classify as stylesheet")
        #expect(cancelled("/probe/xhr.json?"), "a fetch should classify as xmlhttprequest")
        #expect(cancelled("/probe/xhr-plain?"), "Sec-Fetch-Dest names a fetch even with no path extension")
        #expect(cancelled("/probe/face.woff2?"), "a FontFace load should classify as font")
        #expect(cancelled("/probe/frame?"), "an <iframe src> should classify as sub_frame")
        #expect(!cancelled("/probe/image-control?"), "a mismatched want= must not cancel: \(served)")
        #expect(!cancelled("/probe/xhr-control.json?"), "a mismatched want= must not cancel: \(served)")

        // WebSocket handshakes do not go through the injected bundle's resource
        // load client on every WebKit build, so this reports rather than fails.
        print("PROBE websocket cancelled=\(cancelled("/probe/socket?"))")
    }

    /// A listener that cancels everything still must not cancel the page itself.
    /// WebKit reports a blanked main resource as a failed navigation, which used
    /// to swap the whole tab for an error view.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func onBeforeRequestNeverCancelsTheMainDocument() async throws {
        guard #available(macOS 15.4, *) else { return }

        let directory = try makeExtension(background: ["scripts": ["bg.js"]])
        defer { try? FileManager.default.removeItem(at: directory) }
        try "browser.webRequest.onBeforeRequest.addListener(() => ({ cancel: true }), "
            .appending("{ urls: ['<all_urls>'] }, ['blocking']);\n")
            .write(to: directory.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8)
        #expect(try ExtensionShim.apply(at: directory))

        let engine = ExtensionEngine()
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let port = try await server.start()

        let webView = try loopbackWebView(engine: engine)
        defer { webView.window?.close() }

        let id = "aura-cancel-everything"
        _ = try await engine.load(directory: directory, id: id)
        defer { engine.unload(id: id) }
        let ready = await waitForBroker(id)
        #expect(ready)
        guard ready else { return }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/index.html"))
        let loaded = await load(url, in: webView, timeout: 25)
        #expect(loaded, "the document itself was cancelled; the tab would be blank")
        #expect(webView.url?.absoluteString == url.absoluteString, "got \(webView.url?.absoluteString ?? "nil")")
        #expect(server.servedPaths.contains("/index.html"))
        // Everything under the document is fair game and should be gone.
        #expect(!server.servedPaths.contains("/tracker.js"))
    }

    /// A `redirectUrl` verdict rewrites the request before it exists, so the
    /// original never reaches the network and the replacement does.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func aRedirectVerdictSwapsTheRequestBeforeItLeaves() async throws {
        guard #available(macOS 15.4, *) else { return }

        let server = try LocalHTTPServer()
        defer { server.stop() }
        let port = try await server.start()

        let directory = try makeExtension(background: ["scripts": ["bg.js"]])
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        const replacement = 'http://127.0.0.1:\(port)/neutered.js';
        browser.webRequest.onBeforeRequest.addListener(
            details => (details.url.includes('/tracker.js') ? { redirectUrl: replacement } : {}),
            { urls: ['<all_urls>'] },
            ['blocking']
        );
        """
        try script.write(to: directory.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8)
        #expect(try ExtensionShim.apply(at: directory))

        let engine = ExtensionEngine()
        let webView = try loopbackWebView(engine: engine)
        defer { webView.window?.close() }

        let id = "aura-redirect-test"
        _ = try await engine.load(directory: directory, id: id)
        defer { engine.unload(id: id) }
        let ready = await waitForBroker(id)
        #expect(ready)
        guard ready else { return }

        webView.load(URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/index.html"))))
        let state = try await settledPageState(of: webView)
        let served = server.servedPaths

        #expect(!served.contains("/tracker.js"), "the original still went out: \(served)")
        #expect(served.contains("/neutered.js"), "the replacement never went out: \(served)")
        #expect(state["script"] as? String == "load", "the redirected script should still run")
    }

    /// Unloading an extension has to take its listeners with it. WebKit does not
    /// always disconnect the native ports the shim opened, and a listener left
    /// behind keeps the injected bundle asking a port nobody answers on, which
    /// charges every request on every page the full timeout.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func unloadingAnExtensionTakesItsListenersWithIt() async throws {
        guard #available(macOS 15.4, *) else { return }

        let directory = try makeBlockingExtension()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try ExtensionShim.apply(at: directory))

        let engine = ExtensionEngine()
        let id = "aura-unload-test"
        _ = try await engine.load(directory: directory, id: id)
        let ready = await waitForBroker(id)
        #expect(ready)
        guard ready else {
            engine.unload(id: id)
            return
        }
        #expect(WebRequestBroker.shared.isActive)

        engine.unload(id: id)
        #expect(!WebRequestBroker.shared.hasBlockingListener(for: id), "the listener outlived its extension")
        #expect(!WebRequestBroker.shared.isActive, "the bundle would keep asking after an unload")
        #expect(!ExtensionMessageRelay.shared.hasBackground(for: id))
    }

    /// A background page that stops answering. It registers a blocking listener
    /// and then wedges its own thread, which is what a real one looks like after
    /// it throws mid-start-up. Without the circuit breaker every subresource on
    /// every page pays `WebRequestBroker.timeout`.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func aWedgedBackgroundPageStopsBeingAsked() async throws {
        guard #available(macOS 15.4, *) else { return }

        let directory = try makeExtension(background: ["scripts": ["bg.js"]])
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.wedgedBackground.write(
            to: directory.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8
        )
        #expect(try ExtensionShim.apply(at: directory))

        let engine = ExtensionEngine()
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let port = try await server.start()

        let webView = try loopbackWebView(engine: engine)
        defer { webView.window?.close() }

        let id = "aura-wedged-test"
        _ = try await engine.load(directory: directory, id: id)
        defer { engine.unload(id: id) }
        let ready = await waitForBroker(id)
        #expect(ready)
        guard ready else { return }
        // The active flag is pushed to live web processes one way, so the page
        // has to start after it lands or the bundle asks nothing at all.
        try? await Task.sleep(for: .seconds(2))

        let latenciesBefore = WebRequestBroker.shared.latencies.count
        let started = Date()
        let loaded = await load(try #require(URL(string: "http://127.0.0.1:\(port)/index.html")),
                                in: webView, timeout: 40)
        let penalty = Date().timeIntervalSince(started) * 1000
        print(String(format: "BENCH deadlistener page_load_ms=%.0f muted=%@ answered=%d requests=%d",
                     penalty, WebRequestBroker.shared.isMuted(id) ? "yes" : "no",
                     WebRequestBroker.shared.latencies.count - latenciesBefore, server.servedPaths.count))

        #expect(loaded, "a wedged listener must not stop the page loading")
        #expect(WebRequestBroker.shared.isMuted(id), "the broker kept asking an extension that never answers")
        // The printed millisecond figure is the page-load penalty. It is left
        // unasserted on purpose: this fixture page has six subresources, so the
        // number is dominated by whatever else the machine is doing.
    }

    /// Fifty pages opening a tunnelled port and going away. Every one of them
    /// used to leave its port in the relay's owner table, because WebKit does not
    /// always call the disconnect handler for a web view that was torn down.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func tunnelledPortsDoNotLeakAcrossManyPageOpens() async throws {
        guard #available(macOS 15.4, *) else { return }

        let directory = try makeRelayExtension()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try ExtensionShim.apply(at: directory))

        let engine = ExtensionEngine()
        let id = "aura-port-leak-test"
        _ = try await engine.load(directory: directory, id: id)
        defer { engine.unload(id: id) }

        let context = try #require(engine.context(for: id))
        let attached = await poll(timeout: 20) { ExtensionMessageRelay.shared.hasBackground(for: id) }
        #expect(attached)
        guard attached else { return }

        let before = ExtensionMessageRelay.shared.openPortCount(for: id)
        let optionsPage = try #require(context.optionsPageURL)
        var peak = before
        for _ in 0 ..< 50 {
            let page = try extensionPageWebView(for: context)
            page.load(URLRequest(url: optionsPage))
            _ = await poll(timeout: 10) {
                (try? await page.evaluateJavaScript("window.__auraDone === true")) as? Bool == true
            }
            peak = max(peak, ExtensionMessageRelay.shared.openPortCount(for: id))
            page.window?.close()
            page.removeFromSuperview()
        }
        // A closed port is reaped either by its own handler or by the next page
        // attaching, so one more open is what settles the count.
        let settle = try extensionPageWebView(for: context)
        settle.load(URLRequest(url: optionsPage))
        _ = await poll(timeout: 10) {
            ExtensionMessageRelay.shared.openPortCount(for: id) <= 2
        }
        settle.window?.close()
        let after = ExtensionMessageRelay.shared.openPortCount(for: id)

        print("RELAY ports before=\(before) peak=\(peak) after=\(after) over 50 opens")
        #expect(after <= 2, "50 page opens leaked \(after) tunnelled ports")
    }

    // MARK: - The bundled blocker

    // `uBlockOriginBlocksAnEasyListHit` lived here. It proved full uBlock Origin's
    // static filtering engine cancelling an EasyList hit through the injected
    // bundle, and it went with the add-on: uBlock Origin Lite blocks through
    // declarativeNetRequest, which WebKit compiles and enforces itself, with no
    // broker hop to observe. What guards the swap now is
    // `firstLaunchUnpacksTheBundledBlocker`, which fails if the shipped archive
    // ever stops being a DNR blocker.

    private func unpackBundledUBlock() throws -> URL {
        let profile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-ublock-\(UUID().uuidString)", isDirectory: true)
        let installed = try Self.installBundledUBlock(into: profile)
        return try #require(installed, "the add-on has to ship inside the app; nothing downloads at test time")
    }

    /// The same call first launch makes, minus the "have we done this" marker and
    /// the removal of the blocker this one replaced.
    static func installBundledUBlock(into profile: URL) throws -> URL? {
        guard let archive = BundledExtensions.archiveURL else { return nil }
        return try BundledExtensions.unpack(archive, named: BundledExtensions.folderID, into: profile)
    }

    // MARK: - Intra-extension messaging

    /// A page connects to its own background page, round-trips a message and
    /// disconnects, with the background seeing all three. Every hop is real:
    /// WebKit's extension runtime, two native ports, and Aura's relay between
    /// them. WKWebExtension delivers none of this on its own.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func anExtensionPageReachesItsBackgroundPage() async throws {
        guard #available(macOS 15.4, *) else { return }

        let directory = try makeRelayExtension()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try ExtensionShim.apply(at: directory))

        let engine = ExtensionEngine()
        let id = "aura-relay-test"
        _ = try await engine.load(directory: directory, id: id)
        defer { engine.unload(id: id) }

        let context = try #require(engine.context(for: id))
        let attached = await poll(timeout: 20) { ExtensionMessageRelay.shared.hasBackground(for: id) }
        #expect(attached, "the background shim never opened its relay port")
        guard attached else { return }

        let webView = try extensionPageWebView(for: context)
        defer { webView.window?.close() }
        webView.load(URLRequest(url: try #require(context.optionsPageURL)))

        let done = await poll(timeout: 30) {
            (try? await webView.evaluateJavaScript("window.__auraDone === true")) as? Bool == true
        }
        let log = (try? await webView.evaluateJavaScript("JSON.stringify(window.__auraLog || null)")) as? String
        #expect(done, "the page never finished its round trip; log: \(log ?? "nil")")
        guard done, let log, let data = log.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        #expect(result["name"] as? String == "first", "port.name has to survive the tunnel")
        #expect((result["echo"] as? [String: Any])?["hello"] as? Int == 1)
        let senderURL = result["senderUrl"] as? String ?? ""
        #expect(
            senderURL.hasPrefix(context.baseURL.absoluteString),
            "uBlock Origin decides a port is privileged from sender.url; got \(senderURL)"
        )
        #expect(result["disconnects"] as? Int == 1, "the background page has to see the page's disconnect")
        #expect((result["oneShot"] as? [String: Any])?["pong"] as? String == "ping")

        print("RELAY page->background round trip: \(log)")
    }

    /// The bundled blocker's own popup and dashboard, rendered by WebKit and read
    /// back out of their web views. Blank is the failure this fixes.
    ///
    /// The assertions stay off uBlock Origin Lite's own markup on purpose: this is
    /// about WebKit building the views and the relay carrying their ports, and a
    /// blocker update is free to rename every element in there.
    @Test(.enabled(if: WebRequestBrokerTests.isEnabled))
    @MainActor
    func bundledBlockersPopupAndDashboardRender() async throws {
        guard #available(macOS 15.4, *) else { return }

        let directory = try unpackBundledUBlock()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try ExtensionShim.apply(at: directory))

        let engine = ExtensionEngine()
        let id = BundledExtensions.folderID
        _ = try await engine.load(directory: directory, id: id)
        defer { engine.unload(id: id) }

        let context = try #require(engine.context(for: id))
        let attached = await poll(timeout: 60) { ExtensionMessageRelay.shared.hasBackground(for: id) }
        #expect(attached, "the blocker's background page never opened its relay port")
        guard attached else { return }
        // It compiles its rule sets before it answers anything.
        try? await Task.sleep(for: .seconds(10))

        let action = try #require(context.action(for: nil))
        #expect(action.presentsPopup)
        let popup = try #require(action.popupWebView, "WebKit built no popup web view")

        // Text on screen is the whole point: an empty body is the blank popup.
        let filled = await poll(timeout: 30) {
            let text = (try? await popup.evaluateJavaScript(
                "(document.body || {}).innerText || \'\'"
            )) as? String
            return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let report = (try? await popup.evaluateJavaScript(Self.popupReport)) as? String ?? "nil"
        print("UBOL POPUP \(report)")

        #expect(filled, "the popup rendered nothing: \(report)")
        #expect(ExtensionMessageRelay.shared.openPortCount(for: id) > 0, "the popup's port should be tunnelled")

        // The dashboard is the harder case: a page in a tab that frames another
        // page, each one connecting on its own.
        let dashboard = try extensionPageWebView(for: context)
        defer { dashboard.window?.close() }
        let options = try #require(context.optionsPageURL, "the blocker has to declare an options page")
        dashboard.load(URLRequest(url: options))

        let painted = await poll(timeout: 45) {
            let text = (try? await dashboard.evaluateJavaScript(
                "(document.body || {}).innerText || \'\'"
            )) as? String
            return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        #expect(painted, "the dashboard came up empty")
    }

    /// What the popup looks like from the inside, as one JSON line in the log.
    /// Diagnostics only: nothing here is asserted, so a blocker update renaming
    /// its own elements changes the log line rather than the verdict.
    private static let popupReport = """
    JSON.stringify({
        url: location.href,
        role: globalThis.__auraShimRole || null,
        shim: globalThis.__auraShimInstalled || null,
        relay: globalThis.__auraShimRelay,
        port: typeof vAPI === 'object' && vAPI.messaging ? vAPI.messaging.port !== null : null,
        text: ((document.body || {}).innerText || '').slice(0, 200),
        bodyClass: document.body ? document.body.className : ''
    })
    """

    @available(macOS 15.4, *)
    @MainActor
    private func extensionPageWebView(for context: WKWebExtensionContext) throws -> WKWebView {
        let configuration = try #require(context.webViewConfiguration, "the context has to be loaded first")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        webView.isInspectable = true
        let window = NSWindow(
            contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        return webView
    }

    private func poll(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// A background page that echoes and counts disconnects, plus an options
    /// page that drives the whole sequence.
    private func makeRelayExtension() throws -> URL {
        let directory = try ExtensionPagePatchTests.makeExtension()
        try Self.relayBackground.write(
            to: directory.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8
        )
        try Self.relayPage.write(
            to: directory.appendingPathComponent("options.js"), atomically: true, encoding: .utf8
        )
        let page = "<!doctype html><html><head><meta charset=\"utf-8\"></head>"
            + "<body><script src=\"options.js\"></script></body></html>"
        try page.write(to: directory.appendingPathComponent("options.html"), atomically: true, encoding: .utf8)
        return directory
    }

    private static let relayBackground = """
    let disconnects = 0;
    browser.runtime.onConnect.addListener(port => {
        const sender = port.sender || {};
        port.onDisconnect.addListener(() => { disconnects += 1; });
        port.onMessage.addListener((message, replyPort) => {
            if (message && message.what === 'status') {
                replyPort.postMessage({ disconnects: disconnects });
                return;
            }
            replyPort.postMessage({ echo: message, name: replyPort.name, senderUrl: sender.url });
        });
    });
    browser.runtime.onMessage.addListener(message => Promise.resolve({ pong: message && message.ping }));
    """

    private static let relayPage = """
    (async () => {
        const log = {};
        window.__auraLog = log;
        const answer = (port, message) => new Promise(resolve => {
            port.onMessage.addListener(resolve);
            port.postMessage(message);
        });
        try {
            const first = browser.runtime.connect({ name: 'first' });
            Object.assign(log, await answer(first, { hello: 1 }));
            first.disconnect();
            await new Promise(resolve => setTimeout(resolve, 500));
            const second = browser.runtime.connect({ name: 'second' });
            Object.assign(log, await answer(second, { what: 'status' }));
            log.oneShot = await browser.runtime.sendMessage({ ping: 'ping' });
            window.__auraDone = true;
        } catch (error) {
            log.error = String(error);
        }
    })();
    """

    // MARK: - Fixtures for the type probe and the wedged listener

    /// Cancels a request only when the classifier agreed with the `want=` the
    /// URL carries, which turns "was it served" into the whole assertion.
    private static let typeProbeBackground = """
    browser.webRequest.onBeforeRequest.addListener(details => {
        let want = null;
        try { want = new URL(details.url).searchParams.get('want'); } catch (error) { want = null; }
        return { cancel: want !== null && want === details.type };
    }, { urls: ['<all_urls>'] }, ['blocking']);
    """

    /// One request per resource kind, each labelled with the type it should be
    /// classified as. The two `-control` paths carry the wrong label on purpose.
    private static let typeProbePage = """
    <!doctype html><meta charset="utf-8">
    <link rel="stylesheet" href="/probe/style.css?want=stylesheet">
    <body>
    <img src="/probe/image?want=image">
    <img src="/probe/image-control?want=script">
    <script src="/probe/script.js?want=script"></script>
    <iframe src="/probe/frame?want=sub_frame"></iframe>
    <script>
    fetch('/probe/xhr.json?want=xmlhttprequest').catch(function () {});
    fetch('/probe/xhr-plain?want=xmlhttprequest').catch(function () {});
    fetch('/probe/xhr-control.json?want=image').catch(function () {});
    new FontFace('AuraProbe', 'url(/probe/face.woff2?want=font)').load().catch(function () {});
    try { new WebSocket(location.origin.replace('http', 'ws') + '/probe/socket?want=websocket'); }
    catch (error) { /* the fixture server does not speak WebSocket */ }
    </script>
    </body>
    """

    /// A listener that takes far longer than the broker will wait. The host sees
    /// exactly what it sees from a background page that stopped servicing its
    /// run loop: the ask goes out, the deadline passes, the verdict turns up too
    /// late to be wanted. Blocking inside the listener rather than on a timer,
    /// because WebKit does not run a background page's timers reliably.
    private static let wedgedBackground = """
    browser.webRequest.onBeforeRequest.addListener(
        () => {
            const end = Date.now() + 500;
            while (Date.now() < end) { /* too slow on purpose */ }
            return { cancel: false };
        },
        { urls: ['<all_urls>'] },
        ['blocking']
    );
    """

    /// A web view on the injected-bundle pool with `engine`'s extensions
    /// attached, in a real window so WebKit does not throttle it.
    @available(macOS 15.4, *)
    @MainActor
    private func loopbackWebView(engine: ExtensionEngine) throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = try #require(AuraWebBundle.processPool)
        configuration.webExtensionController = engine.controller
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        return webView
    }

    /// Loads `url` and waits for that document, not the empty one the web view
    /// starts on: a fresh WKWebView is already sitting on about:blank with
    /// `readyState` at "complete", so waiting on readyState alone returns before
    /// the load has even begun.
    @MainActor
    private func load(_ url: URL, in webView: WKWebView, timeout: TimeInterval) async -> Bool {
        webView.load(URLRequest(url: url))
        return await poll(timeout: timeout) {
            let here = (try? await webView.evaluateJavaScript("location.href")) as? String
            guard here == url.absoluteString else { return false }
            return ((try? await webView.evaluateJavaScript("document.readyState")) as? String) == "complete"
        }
    }

    /// Waits until the fixture server has gone a full second without a new
    /// request, which is what "the page issued everything it was going to" looks
    /// like from the outside.
    private func settledPaths(of server: LocalHTTPServer, timeout: TimeInterval = 25) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var last = server.servedPaths.count
        var quietSince = Date()
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            let now = server.servedPaths.count
            if now != last {
                last = now
                quietSince = Date()
                continue
            }
            if now > 0, Date().timeIntervalSince(quietSince) > 1 { break }
        }
        return server.servedPaths
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

/// The parts of the broker that are plain value logic. No web process, no
/// extension, so these run without the `AURA_BUNDLE` gate the suite above needs.
struct WebRequestPureTests {
    // MARK: - Match patterns

    /// Chrome folds case over the scheme and the host, and only over those. A
    /// filter list written with a capitalised host has to match the lowercase
    /// URL the browser actually requests.
    @Test
    func matchPatternsFoldCaseOverSchemeAndHostOnly() {
        #expect(MatchPattern("*://YouTube.com/*")?.matches("https://youtube.com/watch") == true)
        #expect(MatchPattern("*://youtube.com/*")?.matches("HTTPS://YouTube.COM/watch") == true)
        #expect(MatchPattern("HTTPS://example.com/*")?.matches("https://example.com/a") == true)
        // The path is case-sensitive, so a pattern aimed at /Ads/ leaves /ads/ alone.
        #expect(MatchPattern("*://example.com/Ads/*")?.matches("https://example.com/ads/x") == false)
        #expect(MatchPattern("*://example.com/Ads/*")?.matches("https://example.com/Ads/x") == true)
        #expect(MatchPattern("<all_urls>")?.matches("HTTPS://example.com/a") == true)
        // A host wildcard is one label deep, not a licence to swallow the path.
        #expect(MatchPattern("*://*.example.com/*")?.matches("https://ads.example.com/x") == true)
        #expect(MatchPattern("*://ads.example/*")?.matches("https://evil.test/?u=http://ads.example/x") == false)
    }

    // MARK: - The wait

    /// The premise of the private wait mode. `decide` parks the main thread in
    /// it, so the reply still has to arrive, while a timer scheduled the
    /// ordinary way must not run: spinning the default mode ran TabManager's
    /// maintenance sweep, which could hibernate the very web view whose request
    /// was being decided, and DownloadManager's progress timers.
    @Test
    @MainActor
    func theWaitModeTakesRepliesAndLeavesTimersAlone() {
        guard #available(macOS 15.4, *) else { return }

        // WebKit hands the port reply over on a run loop source registered for
        // the common modes. `waitMode` is registered as one of those, so such a
        // source fires inside the wait. The main dispatch queue rides along in
        // the app but cannot be asserted here: the test body is itself a
        // main-queue block, and CoreFoundation refuses to nest that drain in
        // any mode.

        let signalled = Flag()
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(signalled).toOpaque()
        context.perform = { info in
            guard let info else { return }
            Unmanaged<Flag>.fromOpaque(info).takeUnretainedValue().isSet = true
        }
        let source = try? #require(CFRunLoopSourceCreate(nil, 0, &context))
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        defer { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFRunLoopSourceSignal(source)

        let quiet = Flag()
        let quietTimer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            quiet.isSet = true
        }
        Self.spin(WebRequestBroker.waitMode, for: 0.05)
        quietTimer.invalidate()

        #expect(signalled.isSet, "the reply's kind of source has to fire inside the wait")
        #expect(!quiet.isSet, "a timer scheduled the ordinary way must not run inside the wait")

        // The control: the same timer does run in the mode the broker used to
        // spin, which is what made the old wait unsafe.
        let noisy = Flag()
        let noisyTimer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            noisy.isSet = true
        }
        Self.spin(.defaultMode, for: 0.05)
        noisyTimer.invalidate()
        #expect(noisy.isSet, "the default mode is what runs those timers")
    }

    private static func spin(_ mode: CFRunLoopMode, for seconds: CFTimeInterval) {
        let deadline = CFAbsoluteTimeGetCurrent() + seconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            CFRunLoopRunInMode(mode, 0.002, true)
        }
    }

    // MARK: - Merging verdicts

    /// Chrome asks every interested extension and then reconciles the answers.
    /// The broker used to return on whichever reply landed first, so a second
    /// extension's `cancel` was thrown away whenever a first one allowed.
    @Test
    func aCancelFromAnyExtensionBeatsAnAllow() {
        #expect(WebRequestVerdict.merge([]) == .allow)
        #expect(WebRequestVerdict.merge([.allow, .allow]) == .allow)
        #expect(WebRequestVerdict.merge([.allow, .cancel]) == .cancel)
        #expect(WebRequestVerdict.merge([.cancel, .allow]) == .cancel)
        // A cancel outranks a redirect however they are ordered: the request
        // must not be made at all.
        #expect(WebRequestVerdict.merge([.redirect("https://a.test/"), .cancel]) == .cancel)
        #expect(WebRequestVerdict.merge([.cancel, .redirect("https://a.test/")]) == .cancel)
    }

    @Test
    func aRedirectAppliesWhenNobodyCancelled() {
        #expect(WebRequestVerdict.merge([.allow, .redirect("https://a.test/")]) == .redirect("https://a.test/"))
        // Two redirects are a real conflict; the caller's order decides, and it
        // has to decide the same way twice.
        let conflict: [WebRequestVerdict] = [.redirect("https://a.test/"), .redirect("https://b.test/")]
        #expect(WebRequestVerdict.merge(conflict) == .redirect("https://a.test/"))
        #expect(WebRequestVerdict.merge(conflict) == WebRequestVerdict.merge(conflict))
    }

    /// The shim speaks JSON, so what the merge reads and what the bundle is
    /// handed both have to survive the dictionary round trip.
    @Test
    func verdictsSurviveTheShimsJSON() {
        #expect(WebRequestVerdict(message: [:]) == .allow)
        #expect(WebRequestVerdict(message: ["cancel": false]) == .allow)
        #expect(WebRequestVerdict(message: ["cancel": true]) == .cancel)
        // An empty redirect is what the shim sends for "no opinion".
        #expect(WebRequestVerdict(message: ["redirectUrl": ""]) == .allow)
        #expect(WebRequestVerdict(message: ["redirectUrl": "https://a.test/"]) == .redirect("https://a.test/"))
        // A cancel wins inside a single answer too.
        #expect(WebRequestVerdict(message: ["cancel": true, "redirectUrl": "https://a.test/"]) == .cancel)

        #expect(WebRequestVerdict.allow.payload.isEmpty)
        #expect(WebRequestVerdict.cancel.payload["cancel"] as? Bool == true)
        #expect(WebRequestVerdict.redirect("https://a.test/").payload["redirectUrl"] as? String == "https://a.test/")
        // `cacheable` belongs to the broker, never to a verdict.
        #expect(WebRequestVerdict.cancel.payload["cacheable"] == nil)
    }

    // MARK: - Asks that arrive mid-decision

    /// The bug: an ask that landed while another was being decided returned a
    /// verdict with no `cancel` field, which the bundle reads as allow. A page
    /// firing eighty subresources at once had most of them admitted without any
    /// extension seeing them, so blocking was probabilistic exactly under the
    /// load where it matters. They are served now.
    @Test
    func anAskArrivingMidDecisionIsServedRatherThanWavedThrough() {
        var gate = WebRequestAskGate()
        let first = gate.admit()
        #expect(first)
        #expect(gate.isBusy)
        let second = gate.admit()
        #expect(second, "an ask that arrives mid-decision has to be served, not allowed")
        #expect(gate.depth == 2)
    }

    /// The cap is what a pathological page cannot get past: every parked ask is
    /// a stack frame and a share of the main thread's time.
    @Test
    func theAskGateStopsAtItsDepthCap() {
        var gate = WebRequestAskGate()
        var admitted = 0
        for _ in 0 ..< WebRequestAskGate.maxDepth where gate.admit() { admitted += 1 }
        #expect(admitted == WebRequestAskGate.maxDepth)
        let overflow = gate.admit()
        #expect(overflow == false)
        #expect(gate.depth == WebRequestAskGate.maxDepth, "a refused ask must not take a slot")
    }

    @Test
    func theAskGateDrainsAsDecisionsFinish() {
        var gate = WebRequestAskGate()
        for _ in 0 ..< WebRequestAskGate.maxDepth { _ = gate.admit() }
        gate.release()
        let afterOneFinished = gate.admit()
        #expect(afterOneFinished, "one finished decision makes room for the next ask")

        for _ in 0 ... WebRequestAskGate.maxDepth { gate.release() }
        #expect(gate.depth == 0, "more releases than admits must not go negative")
        #expect(!gate.isBusy)
        let afterDraining = gate.admit()
        #expect(afterDraining, "a drained gate serves again")
    }

    /// What the bundle is told when the gate is full. Allowed, because there is
    /// nothing else a synchronous reply can say, but never remembered: the next
    /// occurrence has to ask again instead of reusing an answer no extension gave.
    @Test
    @available(macOS 15.4, *)
    func anOverflowingAskIsAllowedButNeverRemembered() {
        let verdict = WebRequestBroker.unansweredVerdict
        #expect(verdict["cancel"] == nil)
        #expect(verdict["redirectUrl"] == nil)
        #expect(verdict["cacheable"] as? Bool == false)
    }

    // MARK: - Request headers

    /// The shim sends the difference against the headers it was handed, and the
    /// bundle applies exactly that. Both halves have to survive the JSON round trip,
    /// including the empty case, which must stay the same bytes an allow always was.
    @Test
    func headerPatchesSurviveTheShimsJSON() {
        #expect(WebRequestHeaderPatch(message: [:]).isEmpty)
        #expect(WebRequestHeaderPatch(message: [:]).payload.isEmpty)

        let patch = WebRequestHeaderPatch(message: [
            "setHeaders": ["Referer": "https://a.test/", "X-Bad": 7],
            "removeHeaders": ["Cookie", "X-Client-Data"]
        ])
        #expect(patch.setHeaders == ["Referer": "https://a.test/"], "a non-string value is not a header")
        #expect(patch.removedHeaders == ["cookie", "x-client-data"], "names fold to lowercase")
        #expect(patch.payload["setHeaders"] as? [String: String] == ["Referer": "https://a.test/"])
        #expect(patch.payload["removeHeaders"] as? [String] == ["cookie", "x-client-data"])
    }

    /// Same rule the redirect merge follows: the caller passes answers in a stable
    /// order, so two extensions naming one header always resolve the same way.
    @Test
    func headerPatchesMergeWithTheFirstAnswerWinning() {
        let first = WebRequestHeaderPatch(message: ["setHeaders": ["DNT": "1"]])
        let second = WebRequestHeaderPatch(message: ["setHeaders": ["DNT": "0", "X-Extra": "y"]])
        let merged = WebRequestHeaderPatch.merge([first, second])
        #expect(merged.setHeaders["DNT"] == "1")
        #expect(merged.setHeaders["X-Extra"] == "y")

        // Setting a header outranks removing it: the extension that set a value said
        // what it wants sent, and an empty removal list keeps the reply small.
        let removing = WebRequestHeaderPatch(message: ["removeHeaders": ["dnt", "cookie"]])
        let conflict = WebRequestHeaderPatch.merge([first, removing])
        #expect(conflict.setHeaders["DNT"] == "1")
        #expect(conflict.removedHeaders == ["cookie"])
        #expect(WebRequestHeaderPatch.merge([]).isEmpty)
    }

    /// The state string is a bit mask now. "0" and "1" still mean what they meant
    /// before headers existed, which is what keeps an old bundle and a new host from
    /// disagreeing about the flag they both already understood.
    @Test
    @MainActor
    @available(macOS 15.4, *)
    func theStateFlagsStayCompatibleWithTheOlderTwoValues() {
        // No listener is registered in a unit test run, so this is the "off" value.
        #expect(WebRequestBroker.shared.stateFlags == "0")
        #expect(!WebRequestBroker.shared.wantsRequestHeaders)
        #expect(Int("1")! & 1 == 1, "bit 0 is the flag the bundle already had")
        #expect(Int("3")! & 1 == 1, "an active host with header listeners is still active")
        #expect(Int("3")! & 2 == 2, "bit 1 is the new one")
    }
}

/// Set from a main-thread closure; `@unchecked` because a run loop callback
/// cannot capture a plain `var`.
private final class Flag: @unchecked Sendable {
    var isSet = false
}
