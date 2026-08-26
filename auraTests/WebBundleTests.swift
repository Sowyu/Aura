import Foundation
import Network
import os
import Testing
import WebKit

@testable import Aura

/// The injected bundle ships inside the signed app and is never written to:
/// a file written into a signed bundle breaks its seal and Gatekeeper then
/// calls the app damaged. Blocking itself belongs to uBlock Origin now, so what
/// the bundle carries is covered by `WebRequestBrokerTests`.
///
/// Gated the same way that suite is: pass `TEST_RUNNER_AURA_BUNDLE=1`.
@Suite(.serialized)
struct WebBundleTests {
    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["AURA_BUNDLE"] == "1" || environment["TEST_RUNNER_AURA_BUNDLE"] == "1"
    }

    @Test(.enabled(if: WebBundleTests.isEnabled))
    func injectedBundleStaysInsideTheSignedApp() throws {
        let bundleURL = try #require(AuraWebBundle.builtInBundleURL)
        #expect(FileManager.default.fileExists(atPath: bundleURL.path))
        #expect(bundleURL.path.hasPrefix(Bundle.main.bundlePath))
    }

    /// The whole blocking path rests on four transcribed private symbols and on
    /// pages being hosted in the Development WebContent service. This is the
    /// round trip that says all of it still works on the running OS build.
    @Test(.enabled(if: WebBundleTests.isEnabled))
    @MainActor
    func theBundleAnswersTheStartupProbe() async {
        guard AuraWebBundle.isEnabled else { return }
        #expect(await AuraWebBundle.probe(timeout: 5), "the injected bundle never answered")
        #expect(SettingsStore.shared.requestBlockingUnavailable == false)
    }

    /// The visual stage, end to end on whatever macOS is running: load the fixture on
    /// the bundle pool, snapshot it twice, reach a verdict.
    ///
    /// It asserts only that the probe reaches one and comes back, because every verdict
    /// is a legitimate answer here: `.blank` means this OS build really does purge the
    /// layers, `.painted` means it does not, and `.inconclusive` means an offscreen
    /// window is not enough to reproduce either on this build. Which one it is is what
    /// gets read off the log by hand each OS beta; the reducers behind it are pinned by
    /// `FullUBlockOriginTests`.
    @Test(.enabled(if: WebBundleTests.isEnabled))
    @MainActor
    func thePaintProbeReachesAVerdict() async throws {
        let pool = try #require(AuraWebBundle.processPool)
        let verdict = await AuraWebBundle.PaintProbe.run(pool: pool, settle: 2)
        // swiftlint:disable:next no_print_statements
        print("PAINT PROBE verdict=\(verdict)")
        #expect([.painted, .blank, .inconclusive].contains(verdict))
    }
}

/// The health check behind item 7: when the private-API stack half-breaks, the
/// symptom used to be stalled loads and silently muted extensions with nothing
/// in the interface to say so.
@Suite(.serialized)
struct WebBundleHealthTests {
    /// A failed probe takes blocking off for the session and leaves the stored
    /// preference alone: the next OS build may well fix the stack, and a setting
    /// the app turned off behind the user's back never turns itself back on.
    @Test
    @MainActor
    func aFailedProbeTakesBlockingOffForThisSessionOnly() {
        let store = SettingsStore.shared
        let previousFlag = store.requestBlockingUnavailable
        let previousSetting = store.extensionRequestBlocking
        defer {
            store.requestBlockingUnavailable = previousFlag
            store.extensionRequestBlocking = previousSetting
        }

        store.requestBlockingUnavailable = false
        store.extensionRequestBlocking = true
        AuraWebBundle.markUnavailable("probe timed out in a test")

        #expect(store.requestBlockingUnavailable)
        #expect(store.extensionRequestBlocking, "the stored preference is the user's, not the probe's")
        #expect(AuraWebBundle.isEnabled == false, "no further page may be put on the injected-bundle pool")
    }

    /// The probe answers on the bundle's own traffic: anything the bundle says,
    /// including the active-flag pull every page creation makes, proves the
    /// channel works end to end.
    @Test
    @MainActor
    func anyMessageFromTheBundleCountsAsProofOfLife() {
        let store = SettingsStore.shared
        let previousFlag = store.requestBlockingUnavailable
        defer { store.requestBlockingUnavailable = previousFlag }
        store.requestBlockingUnavailable = false

        AuraWebBundle.noteBundleReplied()
        #expect(AuraWebBundle.didHearFromBundle)
        #expect(store.requestBlockingUnavailable == false)
    }
}

/// What an extension is told a request is. The classifier is shared verbatim
/// with the injected bundle, so it can be exercised here without a web process.
///
/// The bug these pin down: `AuraResourceTypeAny` has every bit set, so walking
/// the mask answered with whichever bit was tested first. Every request whose
/// type could not be inferred came back as `sub_frame`, and uBlock Origin then
/// judged a page's own JSON API by its `$subdocument` filters.
@Suite
struct ResourceTypeNameTests {
    private func name(
        _ path: String,
        accept: String? = nil,
        isMainFrame: Bool = true,
        isMainDocument: Bool = false
    ) -> String {
        guard let url = URL(string: path.hasPrefix("ws") ? path : "https://example.com" + path) else { return "" }
        let mask = AuraResourceTypeMaskForURL(url, accept, isMainFrame)
        return AuraWebRequestTypeName(mask, isMainDocument, !isMainFrame)
    }

    /// The headers WebCore actually sets before `willSendRequest` runs.
    private static let htmlAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    private static let imageAccept = "image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5"
    private static let cssAccept = "text/css,*/*;q=0.1"

    @Test
    func secFetchDestNamesTheKindOutright() {
        let mask = { AuraResourceTypeForFetchDestination($0) }
        #expect(mask("document") == AuraResourceType.document.rawValue)
        #expect(mask("iframe") == AuraResourceType.subdocument.rawValue)
        #expect(mask("script") == AuraResourceType.script.rawValue)
        #expect(mask("style") == AuraResourceType.stylesheet.rawValue)
        #expect(mask("image") == AuraResourceType.image.rawValue)
        #expect(mask("font") == AuraResourceType.font.rawValue)
        #expect(mask("video") == AuraResourceType.media.rawValue)
        #expect(mask("websocket") == AuraResourceType.webSocket.rawValue)
        // What fetch() and XMLHttpRequest send, and the case the URL alone
        // could never answer.
        #expect(AuraWebRequestTypeName(mask("empty"), false, false) == "xmlhttprequest")
        // Unknown or absent means "keep guessing", not "other".
        #expect(mask("") == 0)
        #expect(mask("audioworklet") == 0)
    }

    @Test
    func theAcceptHeaderDecidesWhatItCan() {
        #expect(name("/hero", accept: Self.imageAccept) == "image")
        #expect(name("/theme", accept: Self.cssAccept) == "stylesheet")
        #expect(name("/", accept: Self.htmlAccept, isMainDocument: true) == "main_frame")
        // Same header, inside an iframe: WebCore uses the document accept for a
        // subframe's own document too, which is the only signal that says so.
        #expect(name("/embed", accept: Self.htmlAccept, isMainFrame: false) == "sub_frame")
        // Scripts and fetches share `*/*`, so it has to decide nothing.
        #expect(name("/bundle", accept: "*/*") == "other")
    }

    @Test
    func thePathExtensionCoversWhatTheHeaderDoesNot() {
        #expect(name("/app.js") == "script")
        #expect(name("/app.mjs") == "script")
        #expect(name("/logo.png") == "image")
        #expect(name("/theme.css") == "stylesheet")
        #expect(name("/inter.woff2") == "font")
        #expect(name("/clip.mp4") == "media")
        #expect(name("/data.json") == "xmlhttprequest")
        #expect(name("wss://example.com/socket") == "websocket")
    }

    @Test
    func anUninferrableRequestIsOtherRatherThanASubframe() {
        #expect(name("/api/data") == "other")
        #expect(name("/api/data", isMainFrame: false) == "other")
        // A .html path with no document accept is a fetch, not a frame.
        #expect(name("/partials/menu.html") == "other")
    }

    @Test
    func theTopDocumentOutranksEveryOtherSignal() {
        #expect(AuraWebRequestTypeName(AuraResourceType.image.rawValue, true, false) == "main_frame")
        #expect(AuraWebRequestTypeName(AuraResourceType.any.rawValue, true, false) == "main_frame")
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

// MARK: - Minimal loopback HTTP server

/// One-shot HTTP/1.1 server, just enough to serve the fixture paths and record
/// which ones were actually requested. `Connection: close` on every response so
/// there is no keep-alive framing to parse.
final class LocalHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.aurabrowser.test.httpserver")
    private let lock = NSLock()
    private var requested: [String] = []
    private var headers: [String: [String: String]] = [:]

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

    /// Request headers keyed by path. The resource-type classifier reads
    /// `Accept`, so seeing what actually arrives is how its mapping is checked
    /// against a real WebKit load rather than against an assumption.
    var servedHeaders: [String: [String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return headers
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

            var fields: [String: String] = [:]
            for line in request.split(separator: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[line.startIndex ..< colon].lowercased()
                fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }

            self.lock.lock()
            self.requested.append(path)
            self.headers[path] = fields
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
