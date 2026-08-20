import AppKit
import Foundation
@testable import Aura
import Testing
import WebKit

// swiftlint:disable no_print_statements
// Test output is the deliverable here: the benchmark prints its scores.

/// Runs Speedometer 3.1 twice: once in a bare `WKWebViewConfiguration`, once through the
/// exact configuration `Tab.restoreTransientState` builds. The gap between the two scores
/// is the overhead Aura adds on top of WebKit.
///
/// Opt in with `ORA_BENCH=1`; a full run takes several minutes and needs the network, so
/// CI never pays for it. `xcodebuild` only forwards variables prefixed `TEST_RUNNER_`
/// into the test host, so both spellings are accepted.
@MainActor
struct SpeedometerBenchmark {
    private static let benchmarkURL = URL(
        string: "https://browserbench.org/Speedometer3.1/?startAutomatically=true&iterationCount=5"
    )

    /// Speedometer 3.1 fills `#result-number` only when the whole run finishes. The rest of
    /// the payload proves the run was real: an invalid summary or a missing confidence
    /// interval means a subtest bailed out and the score is not comparable.
    private static let scoreProbe = """
    (function () {
        function text(selector) {
            var element = document.querySelector(selector);
            return element && element.textContent ? element.textContent.trim() : '';
        }
        var summary = document.querySelector('#summary');
        return JSON.stringify({
            score: text('#result-number'),
            confidence: text('#confidence-number'),
            valid: !!summary && summary.classList.contains('valid'),
            progress: text('#info-progress') || text('#info-label'),
            state: document.body ? document.body.className : ''
        });
    })();
    """

    /// Printed when the score never appears, so the selector list can be corrected.
    private static let diagnosticProbe = """
    JSON.stringify({
        title: document.title,
        ready: document.readyState,
        body: (document.body ? document.body.innerText : '').slice(0, 400)
    });
    """

    private struct Target {
        let view: NSView
        let load: (URL) -> Void
        let evaluate: (String, @escaping @Sendable (Any?, Error?) -> Void) -> Void
    }

    nonisolated static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["ORA_BENCH"] == "1" || environment["TEST_RUNNER_ORA_BENCH"] == "1"
    }

    @Test(.enabled(if: SpeedometerBenchmark.isEnabled))
    func speedometerOverheadStaysWithinBudget() async throws {
        let url = try #require(Self.benchmarkURL)

        let plain = makePlainTarget()
        let ora = makeOraTarget()
        let plainWindow = Self.makeWindow(for: plain)
        let oraWindow = Self.makeWindow(for: ora)
        defer {
            plainWindow.close()
            oraWindow.close()
        }

        // The machine this runs on is not idle, so the two configurations take turns:
        // a build starting halfway through must land on both of them, not just one.
        // Round 0 is a warmup that pays for each target's cold website data store.
        var plainScores: [Double] = []
        var oraScores: [Double] = []
        for round in 0 ..< 4 {
            plainWindow.orderFrontRegardless()
            let plainRun = try await runOnce(target: plain, url: url, label: "plain#\(round)")
            oraWindow.orderFrontRegardless()
            let oraRun = try await runOnce(target: ora, url: url, label: "ora#\(round)")

            guard round > 0 else { continue }
            if let value = Double(plainRun) { plainScores.append(value) }
            if let value = Double(oraRun) { oraScores.append(value) }
        }

        let plainScore = try #require(Self.median(of: plainScores))
        let oraScore = try #require(Self.median(of: oraScores))
        print("BENCH plain runs=\(plainScores) ora runs=\(oraScores)")
        print("BENCH plain=\(plainScore) ora=\(oraScore)")

        try #require(plainScore > 0)
        let ratio = oraScore / plainScore
        print("BENCH ratio=\(String(format: "%.4f", ratio))")
        #expect(ratio > 0.97, "Aura config is \(String(format: "%.1f", (1 - ratio) * 100))% slower than plain WebKit")
    }

    // MARK: - Targets

    private func makePlainTarget() -> Target {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        return Target(
            view: webView,
            load: { webView.load(URLRequest(url: $0)) },
            evaluate: { webView.evaluateJavaScript($0, completionHandler: $1) }
        )
    }

    /// Mirrors `Tab.restoreTransientState`: real profile, real user scripts, real privacy
    /// scripts, real content rule lists, real extension controller.
    private func makeOraTarget() -> Target {
        let containerID = UUID()
        let profile = BrowserEngine.shared.makeProfile(identifier: containerID, isPrivate: false)
        let privacySettings = SettingsStore.shared.privacySettings(for: containerID)
        let userScripts = OraBrowserScripts.userScripts()
            + BrowserPrivacyService.privacyScripts(for: privacySettings)
        let page = BrowserEngine.shared.makePage(
            profile: profile,
            configuration: BrowserPageConfiguration.oraDefault(
                userScripts: userScripts,
                privacySettings: privacySettings
            ),
            delegate: nil
        )

        return Target(
            view: page.contentView,
            load: { page.load(URLRequest(url: $0)) },
            evaluate: { page.evaluateJavaScript($0, completion: $1) }
        )
    }

    // MARK: - Driving the run

    /// WebKit throttles timers and rendering in a web view that is not in a visible window,
    /// which would make every score meaningless.
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

    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    private func runOnce(target: Target, url: URL, label: String) async throws -> String {
        let started = Date()
        target.load(url)

        let deadline = started.addingTimeInterval(360)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            let payload = try await string(from: target, script: Self.scoreProbe)
            let fields = Self.decode(payload)

            if let score = fields["score"] as? String, !score.isEmpty {
                let elapsed = Int(Date().timeIntervalSince(started))
                let confidence = fields["confidence"] as? String ?? ""
                let valid = fields["valid"] as? Bool ?? false
                print("BENCH \(label)=\(score) confidence=\(confidence) valid=\(valid) seconds=\(elapsed)")
                return score
            }
        }

        let diagnostics = try await string(from: target, script: Self.diagnosticProbe)
        Issue.record("Speedometer never reported a score for \(label): \(diagnostics)")
        return ""
    }

    private func string(from target: Target, script: String) async throws -> String {
        let value: Any? = try await withCheckedThrowingContinuation { continuation in
            target.evaluate(script) { result, error in
                if let error, (error as NSError).domain == WKErrorDomain {
                    continuation.resume(returning: nil)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result)
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
}

// swiftlint:enable no_print_statements
