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

