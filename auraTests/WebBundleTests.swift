import AppKit
import Foundation
import Network
import os
import Testing
import WebKit

@testable import Aura

// swiftlint:disable no_print_statements
// The matcher benchmark prints its number; that line is the deliverable.

/// Proves the WebKit injected bundle cancels, rewrites and redirects subresources
/// synchronously, before the request reaches the network.
///
/// The WebKit half is gated so it does not run in normal CI: pass
/// `TEST_RUNNER_AURA_BUNDLE=1` to xcodebuild (xcodebuild strips the prefix and
/// sets `AURA_BUNDLE=1` in the runner's environment; both spellings work here).
@Suite(.serialized)
struct WebBundleTests {
    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["AURA_BUNDLE"] == "1" || environment["TEST_RUNNER_AURA_BUNDLE"] == "1"
    }

    /// A block rule wins, an `@@` exception beats it, `$removeparam` strips, `$redirect`
    /// neuters. The two block rules name `ping`/`other` on purpose: those types have no
    /// equivalent in Safari's rule format, which is what puts the rule in the native set.
    private static let fixtureRules = """
    ||127.0.0.1/ads/$image,ping
    ||127.0.0.1/ads/beacon.json$xmlhttprequest,other
    @@||127.0.0.1/ads/ok.png
    $removeparam=utm_source
    ||127.0.0.1/tracker.js$redirect=noopjs
    """

    // MARK: - Injected bundle

    @Test(.enabled(if: WebBundleTests.isEnabled))
    func injectedBundleStaysInsideTheSignedApp() throws {
        let bundleURL = try #require(AuraWebBundle.builtInBundleURL)
        #expect(FileManager.default.fileExists(atPath: bundleURL.path))
        #expect(bundleURL.path.hasPrefix(Bundle.main.bundlePath))
        let rulesURL = try #require(AuraWebBundle.rulesFileURL)
        // Writing into a signed bundle breaks its seal; Gatekeeper then calls the app damaged.
        #expect(!rulesURL.path.hasPrefix(bundleURL.path), "rule file must not live inside the injected bundle")
    }

    @Test(.enabled(if: WebBundleTests.isEnabled))
    @MainActor
    func rulesFileDrivesBlockRewriteAndRedirect() async throws {
        try Self.installFixtureRules()
        let pool = try #require(
            AuraWebBundle.processPool,
            "injected bundle process pool unavailable — private API gone or bundle missing"
        )
        let (state, served) = try await loadTestPage(processPool: pool)

        #expect(state["ok"] as? String == "load", "the @@ exception should let /ads/ok.png through")
        #expect(state["ad"] as? String == "error", "/ads/pixel.png should be cancelled, got \(state["ad"] ?? "nil")")
        #expect(state["fetch"] as? String == "error", "/ads/beacon.json should be cancelled")

        // Independent proof: the cancelled requests never left the web process.
        #expect(served.contains("/index.html"))
        #expect(served.contains("/ads/ok.png"))
        #expect(!served.contains("/ads/pixel.png"), "blocked image still reached the server: \(served)")
        #expect(!served.contains("/ads/beacon.json"), "blocked fetch still reached the server: \(served)")

        // $redirect: the script loads, but from the inline data: stand-in.
        #expect(state["script"] as? String == "load", "redirected script should still fire onload")
        #expect(state["scriptDefined"] as? Bool == false, "the real tracker.js must not have run")
        #expect(!served.contains("/tracker.js"), "redirected script still reached the server: \(served)")

        // $removeparam: the server sees the request with utm_source gone.
        let queried = served.filter { $0.hasPrefix("/page") }
        #expect(queried.contains("/page?keep=1"), "expected /page?keep=1, saw \(queried)")
        #expect(!queried.contains { $0.contains("utm_source") }, "utm_source survived: \(queried)")
    }

    /// Negative control. Without the injected bundle everything loads, so a pass
    /// above can only come from willSendRequestForFrame.
    @Test(.enabled(if: WebBundleTests.isEnabled))
    @MainActor
    func everythingLoadsWithoutTheInjectedBundle() async throws {
        try Self.installFixtureRules()
        let (state, served) = try await loadTestPage(processPool: nil)

        #expect(state["ok"] as? String == "load")
        #expect(state["ad"] as? String == "load", "no bundle, so /ads/ should load, got \(state["ad"] ?? "nil")")
        #expect(state["script"] as? String == "load")
        #expect(state["scriptDefined"] as? Bool == true)
        #expect(state["fetch"] as? String == "load")
        #expect(served.contains("/ads/pixel.png"))
        #expect(served.contains("/tracker.js"))
        #expect(served.contains { $0.contains("utm_source") }, "no bundle, so utm_source should survive")
    }

    private static func installFixtureRules() throws {
        let url = try #require(AuraWebBundle.rulesFileURL)
        let ruleSet = NativeBlockingRuleSet.make(fromFilterLines: fixtureRules.components(separatedBy: "\n"))
        #expect(ruleSet.rules.count == 5, "fixture should produce five rules, got \(ruleSet.rules.count)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ruleSet.jsonData(revision: UUID().uuidString).write(to: url, options: .atomic)
    }

    @MainActor
    private func loadTestPage(processPool: WKProcessPool?) async throws -> ([String: Any], [String]) {
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let port = try await server.start()

        let configuration = WKWebViewConfiguration()
        if let processPool { configuration.processPool = processPool }
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        defer { window.close() }

        guard let url = URL(string: "http://127.0.0.1:\(port)/index.html") else {
            Issue.record("could not build the loopback URL")
            return ([:], [])
        }
        webView.load(URLRequest(url: url))
        let state = try await pollUntilSettled(webView)
        return (state, server.servedPaths)
    }

    @MainActor
    private func pollUntilSettled(_ webView: WKWebView) async throws -> [String: Any] {
        try await settledPageState(of: webView)
    }
}

/// Polls the fixture page's four load flags until none of them is still
/// pending. Shared with WebRequestBrokerTests, which serves the same page.
@MainActor
func settledPageState(of webView: WKWebView) async throws -> [String: Any] {
    let script = """
    JSON.stringify({
        ok: window.__okState || "pending",
        ad: window.__adState || "pending",
        script: window.__scriptState || "pending",
        fetch: window.__fetchState || "pending",
        scriptDefined: window.__loadedScript === true
    })
    """

    let deadline = Date().addingTimeInterval(20)
    var last: [String: Any] = [:]
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let json = try? await webView.evaluateJavaScript(script) as? String,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        last = parsed
        if ["ok", "ad", "script", "fetch"].allSatisfy({ parsed[$0] as? String != "pending" }) {
            // One more beat so the rewritten fetch reaches the server.
            try? await Task.sleep(nanoseconds: 400_000_000)
            return parsed
        }
    }
    Issue.record("page never settled; last state: \(last)")
    return last
}

// MARK: - Rule parsing and matching

/// The half that needs no WebKit: parsing filter lines, serialising them, and
/// matching them with the same C code the injected bundle runs.
struct NativeBlockingRuleTests {
    @Test
    func keepsOnlyTheRulesSafarisFormatDrops() {
        #expect(isIgnored("||ads.example^$image"), "a plain image rule is already in the content rule list")
        #expect(isIgnored("ads.example###banner"), "cosmetic rules belong to the advanced engine")
        #expect(isIgnored("! comment"))

        guard case let .rule(blocked) = NativeBlockingRuleParser.parse(line: "||ads.example^$image,ping") else {
            Issue.record("$ping has no Safari equivalent, so the rule should be recovered")
            return
        }
        #expect(blocked.kind == .block)
        #expect(blocked.host == "ads.example")
        #expect(blocked.pattern == "^")

        guard case let .rule(stripped) = NativeBlockingRuleParser.parse(line: "$removeparam=utm_source") else {
            Issue.record("$removeparam should be recovered")
            return
        }
        #expect(stripped.kind == .removeParam)
        #expect(stripped.parameters == ["utm_source"])

        guard case let .rule(redirected) =
            NativeBlockingRuleParser.parse(line: "||x.example/t.js$script,redirect=noopjs")
        else {
            Issue.record("$redirect should be recovered")
            return
        }
        #expect(redirected.kind == .redirect)
        #expect(redirected.redirect == "noopjs")

        if case .unsupported = NativeBlockingRuleParser.parse(line: "||x.example^$csp=script-src 'none'") {
            // $csp needs a response header rewrite, which the bundle cannot do.
        } else {
            Issue.record("$csp should count as dropped")
        }
    }

    @Test
    func documentExceptionBecomesAnAllowlistedHost() {
        guard case let .allowlistHost(host) = NativeBlockingRuleParser.parse(line: "@@||example.com^$document")
        else {
            Issue.record("a $document exception switches the whole site off")
            return
        }
        #expect(host == "example.com")
    }

    @Test
    func serialisedRulesMatchTheSameWayTheBundleMatchesThem() throws {
        let lines = """
        ||ads.example^$image,ping
        @@||ads.example/ok.png
        $removeparam=utm_source
        ||cdn.example/t.js$script,redirect=noopjs
        """
        let ruleSet = NativeBlockingRuleSet.make(fromFilterLines: lines.components(separatedBy: "\n"))
        #expect(ruleSet.rules.count == 4)

        let rules = try loadedRules(ruleSet)
        #expect(rules.ruleCount == 4)

        #expect(decision(rules, "https://ads.example/pixel.png") == .block)
        #expect(decision(rules, "https://ads.example/ok.png") == .allow)
        #expect(decision(rules, "https://other.example/pixel.png") == .allow)

        var rewritten: NSURL?
        let stripped = rules.decision(
            for: try #require(URL(string: "https://shop.example/page?utm_source=x&keep=1")),
            documentHost: "shop.example",
            typeMask: AuraResourceType.any.rawValue,
            isMainFrame: false,
            resultURL: &rewritten
        )
        #expect(stripped == .rewrite)
        #expect((rewritten as URL?)?.absoluteString == "https://shop.example/page?keep=1")

        var replacement: NSURL?
        let redirected = rules.decision(
            for: try #require(URL(string: "https://cdn.example/t.js")),
            documentHost: "shop.example",
            typeMask: AuraResourceType.script.rawValue,
            isMainFrame: false,
            resultURL: &replacement
        )
        #expect(redirected == .redirect)
        #expect((replacement as URL?)?.absoluteString.hasPrefix("data:application/javascript") == true)
    }

    @Test
    func allowlistedHostsSwitchEverythingOff() throws {
        let ruleSet = NativeBlockingRuleSet.make(
            fromFilterLines: ["||ads.example^$image,ping"],
            allowlist: ["shop.example"]
        )
        let rules = try loadedRules(ruleSet)
        #expect(decision(rules, "https://ads.example/pixel.png", documentHost: "shop.example") == .allow)
        #expect(decision(rules, "https://ads.example/pixel.png", documentHost: "other.example") == .block)
    }

    /// The matcher runs on the thread that is about to start a resource load, so
    /// its cost lands directly in page load time.
    @Test(.enabled(if: WebBundleTests.isEnabled))
    func matcherStaysUnderFiftyMicrosecondsPerLookup() throws {
        var lines: [String] = []
        for index in 0..<5000 {
            lines.append("||ads\(index).example.com^$script,ping")
        }
        lines.append("$removeparam=utm_source")
        let rules = try loadedRules(NativeBlockingRuleSet.make(fromFilterLines: lines))
        #expect(rules.ruleCount == 5001)

        // Half hit an indexed block rule, half miss entirely. No query strings, so
        // this measures matching rather than URL rewriting.
        let urls: [URL] = (0..<100).compactMap { index in
            index.isMultiple(of: 2)
                ? URL(string: "https://ads\(index * 37).example.com/tag.js")
                : URL(string: "https://cdn\(index).example.org/asset\(index).png")
        }
        // The same lookups with a parameter the rule set strips, so the reported
        // cost includes the NSURLComponents rewrite.
        let rewritingURLs: [URL] = urls.compactMap { URL(string: $0.absoluteString + "?utm_source=x&keep=1") }

        let lookups = 10_000
        let matching = Self.averageMicroseconds(over: lookups, rules: rules, urls: urls)
        let rewriting = Self.averageMicroseconds(over: lookups, rules: rules, urls: rewritingURLs)

        print(String(format: "BENCH native-block lookups=%d avg_us=%.2f", lookups, matching))
        print(String(format: "BENCH native-block-rewrite lookups=%d avg_us=%.2f", lookups, rewriting))
        #expect(matching < 50, "per-lookup match cost regressed to \(matching) us")
        #expect(rewriting < 50, "per-lookup rewrite cost regressed to \(rewriting) us")
    }

    // MARK: Helpers

    private static func averageMicroseconds(over lookups: Int, rules: AuraBlockRules, urls: [URL]) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let start = mach_absolute_time()
        for index in 0..<lookups {
            var result: NSURL?
            _ = rules.decision(
                for: urls[index % urls.count],
                documentHost: "publisher.example",
                typeMask: AuraResourceType.any.rawValue,
                isMainFrame: false,
                resultURL: &result
            )
        }
        let nanoseconds = Double(mach_absolute_time() - start) * Double(timebase.numer) / Double(timebase.denom)
        return nanoseconds / Double(lookups) / 1000
    }

    private func isIgnored(_ line: String) -> Bool {
        if case .ignored = NativeBlockingRuleParser.parse(line: line) { return true }
        return false
    }

    private func loadedRules(_ ruleSet: NativeBlockingRuleSet) throws -> AuraBlockRules {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-native-rules-\(UUID().uuidString).json")
        try ruleSet.jsonData(revision: "test").write(to: url)
        let rules = AuraBlockRules()
        #expect(rules.load(fromPath: url.path))
        return rules
    }

    private func decision(
        _ rules: AuraBlockRules,
        _ urlString: String,
        documentHost: String = "publisher.example"
    ) -> AuraBlockDecision {
        guard let url = URL(string: urlString) else { return .allow }
        var result: NSURL?
        return rules.decision(
            for: url,
            documentHost: documentHost,
            typeMask: AuraResourceType.any.rawValue,
            isMainFrame: false,
            resultURL: &result
        )
    }
}

// MARK: - Minimal loopback HTTP server

/// One-shot HTTP/1.1 server, just enough to serve the fixture paths and record
/// which ones were actually requested. `Connection: close` on every response so
/// there is no keep-alive framing to parse.
final class LocalHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.aurabrowser.test.httpserver")
    private let lock = NSLock()
    private var requested: [String] = []

    private static let pixel = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQ"
            + "GAhKmMIQAAAABJRU5ErkJggg=="
    ) ?? Data()

    /// The page this server serves for any `.html` path. Defaults to the
    /// injected-bundle fixture; WebRequestBrokerTests swaps in its own.
    private let html: String

    private static let fixtureHTML = """
    <!doctype html><meta charset="utf-8"><body>
    <img id="ok" src="/ads/ok.png" onload="window.__okState='load'" onerror="window.__okState='error'">
    <img id="ad" src="/ads/pixel.png" onload="window.__adState='load'" onerror="window.__adState='error'">
    <script src="/tracker.js" onload="window.__scriptState='load'" onerror="window.__scriptState='error'"></script>
    <script>
    fetch("/page?utm_source=x&keep=1");
    fetch("/ads/beacon.json")
        .then(function () { window.__fetchState = "load"; })
        .catch(function () { window.__fetchState = "error"; });
    </script>
    </body>
    """

    init(html: String = LocalHTTPServer.fixtureHTML) throws {
        self.html = html
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    var servedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receive(on: connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let claim: () -> Bool = {
                resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if claim() { continuation.resume(returning: self.listener.port?.rawValue ?? 0) }
                case let .failed(error):
                    if claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = request
                .split(separator: "\r\n").first
                .map { $0.split(separator: " ") }
                .flatMap { $0.count > 1 ? String($0[1]) : nil } ?? "/"

            self.lock.lock()
            self.requested.append(path)
            self.lock.unlock()

            connection.send(content: self.response(for: path), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for path: String) -> Data {
        let body: Data
        let type: String
        let basePath = String(path.split(separator: "?").first ?? "")
        switch (basePath as NSString).pathExtension {
        case "html":
            body = Data(html.utf8)
            type = "text/html; charset=utf-8"
        case "js":
            body = Data("window.__loadedScript = true;".utf8)
            type = "text/javascript; charset=utf-8"
        case "json":
            body = Data("{}".utf8)
            type = "application/json"
        case "png":
            body = Self.pixel
            type = "image/png"
        default:
            body = Data("ok".utf8)
            type = "text/plain; charset=utf-8"
        }
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: \(type)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        return Data(head.utf8) + body
    }
}

// swiftlint:enable no_print_statements
