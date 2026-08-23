import AppKit
import Foundation
@testable import Aura
import Testing
import WebKit

// swiftlint:disable no_print_statements
// Test output is the deliverable here: the benchmark prints its timings.

/// Loads five heavy real sites three times each, once with the bundled uBlock Origin
/// Lite loaded through `ExtensionEngine` and once with no extension controller at all.
/// The gap between the two medians is what blocking buys the user on a real page.
///
/// Opt in with `ORA_BENCH_PAGELOAD=1`; thirty loads over the network take about ten
/// minutes, so CI never pays for it. `xcodebuild` only forwards variables prefixed
/// `TEST_RUNNER_` into the test host, so both spellings are accepted.
@MainActor
struct PageLoadBenchmark {
    private static let sites = [
        "https://www.nytimes.com/",
        "https://www.theverge.com/",
        "https://www.reddit.com/",
        "https://www.amazon.com/",
        "https://www.youtube.com/",
    ]

    private static let blockerID = BundledExtensions.folderID

    /// Three loads per arm. Enough for a median to mean something, few enough that the
    /// whole run stays under the patience of whoever started it.
    private static let rounds = 3

    /// Past this a load counts as skipped rather than hanging the suite: some of these
    /// sites keep a socket open forever and never fire `load` on a bad network.
    private static let loadTimeout: TimeInterval = 60

    /// `performance.timing` is the number every other browser benchmark quotes, but it
    /// reads zero on pages served under a navigation-timing-2-only path, so the modern
    /// entry is the fallback. `resource` entries are the request count the page paid for.
    private static let timingProbe = """
    (function () {
        var timing = performance.timing || {};
        var ms = (timing.loadEventEnd || 0) - (timing.navigationStart || 0);
        if (ms <= 0) {
            var entry = performance.getEntriesByType('navigation')[0];
            ms = entry ? entry.loadEventEnd : 0;
        }
        return JSON.stringify({
            ready: document.readyState,
            ms: ms,
            requests: performance.getEntriesByType('resource').length
        });
    })();
    """

    private struct Target {
        let view: NSView
        let load: (URL) -> Void
        let evaluate: (String, @escaping @Sendable (Any?, Error?) -> Void) -> Void
    }

    private struct Sample {
        let milliseconds: Double
        let requests: Double
    }

    nonisolated static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["ORA_BENCH_PAGELOAD"] == "1" || environment["TEST_RUNNER_ORA_BENCH_PAGELOAD"] == "1"
    }

    @Test(.enabled(if: PageLoadBenchmark.isEnabled))
    func pageLoadCostWithAndWithoutTheBundledBlocker() async throws {
        guard #available(macOS 15.4, *) else { return }

        let pool = try #require(AuraWebBundle.processPool, "both arms have to run in the injected bundle's pool")
        let directory = try Self.unpackBundledBlocker()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try ExtensionShim.apply(at: directory)

        let engine = ExtensionEngine()
        _ = try await engine.load(directory: directory, id: Self.blockerID)
        defer { engine.unload(id: Self.blockerID) }

        // uBO Lite blocks through declarativeNetRequest, so WebKit compiles the rule
        // sets rather than the extension registering a listener Aura can watch for.
        // That is about 30 s on a cold profile, and timing a load before it lands
        // measures an extension that is not blocking yet: the "off" arm wearing the
        // wrong label. ponytail: a fixed wait, because nothing exposes "rules
        // compiled". Swap it for the real signal if WebKit ever publishes one.
        try? await Task.sleep(for: .seconds(60))

        for site in Self.sites {
            let url = try #require(URL(string: site))
            let host = url.host() ?? site
            var on: [Sample] = []
            var off: [Sample] = []

            // The arms take turns so a background build starting halfway through the run
            // lands on both of them instead of taxing one.
            for round in 0 ..< Self.rounds {
                if let sample = await measure(url: url, controller: engine.controller,
                                              pool: pool, label: "\(host) ubo=on#\(round)") {
                    on.append(sample)
                }
                if let sample = await measure(url: url, controller: nil,
                                              pool: pool, label: "\(host) ubo=off#\(round)") {
                    off.append(sample)
                }
            }

            Self.report(host: host, on: on, off: off)
            #expect(!on.isEmpty && !off.isEmpty, "\(host) produced no usable sample in one of the arms")
        }
    }

    // MARK: - Reporting

    private static func report(host: String, on: [Sample], off: [Sample]) {
        let onMilliseconds = median(of: on.map(\.milliseconds))
        let offMilliseconds = median(of: off.map(\.milliseconds))
        let onRequests = median(of: on.map(\.requests))
        let offRequests = median(of: off.map(\.requests))

        print("BENCH pageload site=\(host) ubo=on ms=\(format(onMilliseconds)) requests=\(format(onRequests))")
        print("BENCH pageload site=\(host) ubo=off ms=\(format(offMilliseconds)) requests=\(format(offRequests))")

        guard let onMilliseconds, let offMilliseconds, let onRequests, let offRequests else {
            print("BENCH pageload summary site=\(host) delta=n/a samples=on:\(on.count) off:\(off.count)")
            return
        }
        let share = offMilliseconds > 0 ? (offMilliseconds - onMilliseconds) / offMilliseconds * 100 : 0
        print("BENCH pageload summary site=\(host) delta_ms=\(format(offMilliseconds - onMilliseconds))"
            + " delta_requests=\(format(offRequests - onRequests))"
            + " faster=\(String(format: "%.1f", share))% samples=on:\(on.count) off:\(off.count)")
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(Int(value.rounded()))
    }

    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    // MARK: - One load

    @available(macOS 15.4, *)
    private func measure(
        url: URL,
        controller: WKWebExtensionController?,
        pool: WKProcessPool,
        label: String
    ) async -> Sample? {
        let target = Self.makeTarget(controller: controller, pool: pool)
        let window = Self.makeWindow(for: target)
        defer { window.close() }

        let started = Date()
        target.load(url)

        let deadline = started.addingTimeInterval(Self.loadTimeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            let fields = Self.decode(await Self.string(from: target, script: Self.timingProbe))
            guard fields["ready"] as? String == "complete",
                  let milliseconds = (fields["ms"] as? NSNumber)?.doubleValue, milliseconds > 0
            else { continue }

            let requests = (fields["requests"] as? NSNumber)?.doubleValue ?? 0
            print("BENCH pageload \(label) ms=\(Self.format(milliseconds)) requests=\(Self.format(requests))")
            return Sample(milliseconds: milliseconds, requests: requests)
        }

        // A missed load is worth less than a wrong number, so it drops out of the median.
        print("BENCH pageload \(label) skipped: no load event within \(Int(Self.loadTimeout))s")
        return nil
    }

    /// Both arms share everything but the extension controller, so the only difference the
    /// numbers can carry is uBlock itself. The data store is thrown away per load: a warm
    /// cache would flatter whichever arm happened to run second.
    @available(macOS 15.4, *)
    private static func makeTarget(controller: WKWebExtensionController?, pool: WKProcessPool) -> Target {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = pool
        configuration.webExtensionController = controller
        configuration.websiteDataStore = .nonPersistent()
        // The resource timing buffer holds 250 entries by default, and a news
        // front page blows past that, so both arms would report 250 and the
        // whole point of counting requests would be lost.
        configuration.userContentController.addUserScript(WKUserScript(
            source: "performance.setResourceTimingBufferSize(5000);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        return Target(
            view: webView,
            load: { webView.load(URLRequest(url: $0)) },
            evaluate: { webView.evaluateJavaScript($0, completionHandler: $1) }
        )
    }

    /// WebKit throttles timers and rendering in a web view that is not in a visible window,
    /// which would make every timing meaningless.
    private static func makeWindow(for target: Target) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = target.view
        window.orderFrontRegardless()
        return window
    }

    // MARK: - Helpers

    /// Evaluating while the page is still navigating throws, and mid-navigation is most of
    /// what this polls through, so every failure is just "ask again next second".
    private static func string(from target: Target, script: String) async -> String {
        let value: Any? = await withCheckedContinuation { continuation in
            target.evaluate(script) { result, error in
                continuation.resume(returning: error == nil ? result : nil)
            }
        }
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func decode(_ payload: String) -> [String: Any] {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    /// The add-on ships inside the app; nothing downloads at benchmark time.
    private static func unpackBundledBlocker() throws -> URL {
        let profile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-pageload-\(UUID().uuidString)", isDirectory: true)
        let archive = try #require(BundledExtensions.archiveURL, "no bundled blocker to benchmark")
        let installed = try BundledExtensions.unpack(archive, named: BundledExtensions.folderID, into: profile)
        return try #require(installed, "the bundled add-on failed to unpack")
    }
}

// swiftlint:enable no_print_statements
