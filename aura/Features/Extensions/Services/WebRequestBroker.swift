import Foundation
import os
@preconcurrency import WebKit

/// Middle of the blocking `webRequest` bridge.
///
/// Three processes are involved. The injected bundle (WebContent) is parked
/// inside `willSendRequestForFrame` and asks this class over synchronous IPC.
/// This class asks the extension over a native message port, which lands in the
/// extension's own process. The answer comes back the same way, and the web
/// process resumes.
///
/// The UI process main thread is what pays: it spins its run loop until the
/// extension answers or `timeout` runs out. Two things keep that bounded. Only
/// one decision is ever in flight, and a request that arrives while another is
/// being decided is allowed on the spot. Everything else the bundle can do for
/// itself: it never asks at all unless `isActive` was pushed to it, and it
/// caches answers this class marks cacheable.
@available(macOS 15.4, *)
@MainActor
final class WebRequestBroker {
    static let shared = WebRequestBroker()

    /// How long the web process is allowed to wait. Past this the request is
    /// allowed, and the answer is not cached so the next one asks again.
    static let timeout: TimeInterval = 0.15

    private static let log = Logger(subsystem: "com.aurabrowser.app", category: "webrequest")
    nonisolated static let messageName = "aura.webRequest.decide"
    nonisolated static let applicationIdentifier = "app.aurabrowser.bridge"

    /// One blocking listener as the shim announced it.
    private struct Listener {
        let extensionID: String
        let event: String
        let patterns: [MatchPattern]
        let types: Set<String>

        func matches(url: String, type: String) -> Bool {
            guard event == "onBeforeRequest" else { return false }
            if !types.isEmpty, !types.contains(type) { return false }
            if patterns.isEmpty { return true }
            return patterns.contains { $0.matches(url) }
        }
    }

    private var listeners: [Int: Listener] = [:]
    private var ports: [String: WKWebExtension.MessagePort] = [:]
    private var outstanding: Set<Int> = []
    private var answers: [Int: [String: Any]] = [:]
    private var nextRequestID = 1
    private var isDeciding = false

    /// Consecutive timeouts an extension is allowed before it stops being asked.
    /// A background page that wedged (uBlock Origin mid-filter-compile, or one
    /// that threw on start-up) would otherwise charge every single request on
    /// every page the full `timeout`, and a page of 80 subresources turns into
    /// twelve seconds of stalled main thread.
    static let timeoutsBeforeMuting = 3
    /// How long a muted extension is skipped for. Long enough to get a page
    /// loaded, short enough that an extension which recovers is asked again.
    static let muteDuration: TimeInterval = 5

    private var consecutiveTimeouts: [String: Int] = [:]
    private var mutedUntil: [String: Date] = [:]

    /// True while `extensionID` is being skipped for timing out.
    func isMuted(_ extensionID: String) -> Bool {
        guard let until = mutedUntil[extensionID] else { return false }
        if until > Date() { return true }
        mutedUntil.removeValue(forKey: extensionID)
        return false
    }

    /// Round-trip times in milliseconds, newest last. Capped; the tests read the
    /// median off this.
    private(set) var latencies: [Double] = []

    private init() {}

    /// True while some extension has a blocking listener and a port to answer on.
    /// The bundle's active flag follows this.
    var isActive: Bool {
        listeners.values.contains { hasLivePort(for: $0.extensionID) && !isMuted($0.extensionID) }
    }

    func hasBlockingListener(for extensionID: String) -> Bool {
        hasLivePort(for: extensionID) && listeners.values.contains { $0.extensionID == extensionID }
    }

    private func hasLivePort(for extensionID: String) -> Bool {
        guard let port = ports[extensionID] else { return false }
        return !port.isDisconnected
    }

    var medianLatencyMilliseconds: Double? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted()
        return sorted[sorted.count / 2]
    }

    /// Nudges the singleton into existence so a stale state file is cleared
    /// before any page loads.
    static func prepare() {
        _ = shared
    }

    // MARK: - Ports

    /// The shim's `runtime.connectNative` landed. Everything the extension says
    /// after this arrives on `port.messageHandler`.
    func attach(port: WKWebExtension.MessagePort, extensionID: String) {
        ports[extensionID]?.disconnect()
        ports[extensionID] = port

        port.messageHandler = { [weak self] message, _ in
            MainActor.assumeIsolated {
                self?.receive(message, from: extensionID)
            }
        }
        port.disconnectHandler = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.detach(extensionID: extensionID)
            }
        }
        Self.log.info("shim connected for \(extensionID, privacy: .public)")
    }

    func detach(extensionID: String) {
        ports.removeValue(forKey: extensionID)
        listeners = listeners.filter { $0.value.extensionID != extensionID }
        consecutiveTimeouts.removeValue(forKey: extensionID)
        mutedUntil.removeValue(forKey: extensionID)
        writeState()
    }

    /// `runtime.sendNativeMessage` rather than the port. The shim uses it once,
    /// to say what it found, which is the only way a background page's
    /// diagnostics reach the browser.
    @discardableResult
    func receiveOneShot(_ message: Any?, from extensionID: String) -> [String: Any] {
        if let message = message as? [String: Any], message["op"] as? String == "hello" {
            Self.log.debug(
                "shim hello from \(extensionID, privacy: .public): \(String(describing: message), privacy: .public)"
            )
        } else {
            receive(message, from: extensionID)
        }
        return ["ok": true]
    }

    private func receive(_ message: Any?, from extensionID: String) {
        guard let message = message as? [String: Any], let operation = message["op"] as? String else {
            Self.log.debug("unparsed shim message: \(String(describing: message), privacy: .public)")
            return
        }
        switch operation {
        case "register":
            guard let id = message["id"] as? Int, let event = message["event"] as? String else { return }
            let urls = message["urls"] as? [String] ?? ["<all_urls>"]
            let types = Set(message["types"] as? [String] ?? [])
            listeners[key(extensionID, id)] = Listener(
                extensionID: extensionID,
                event: event,
                patterns: urls.compactMap(MatchPattern.init),
                types: types
            )
            writeState()
            Self.log.info("\(extensionID, privacy: .public) registered blocking \(event, privacy: .public)")
        case "unregister":
            guard let id = message["id"] as? Int else { return }
            listeners.removeValue(forKey: key(extensionID, id))
            writeState()
        case "verdict":
            guard let id = message["id"] as? Int, outstanding.contains(id) else { return }
            answers[id] = message
        default:
            break
        }
    }

    /// Listener ids are per-extension, so they need the extension folded in.
    private func key(_ extensionID: String, _ listenerID: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(extensionID)
        hasher.combine(listenerID)
        return hasher.finalize()
    }

    // MARK: - Deciding

    /// Called on the main thread from the injected bundle's synchronous message.
    /// Returns the JSON reply, or nil to leave the request alone.
    func handle(name: String, body: String) -> String? {
        guard name == Self.messageName else { return nil }
        guard let data = body.data(using: .utf8),
              let details = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let verdict = decide(details)
        guard let encoded = try? JSONSerialization.data(withJSONObject: verdict) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private func decide(_ details: [String: Any]) -> [String: Any] {
        // Re-entered from the run loop spin below, with another web process
        // waiting. Serving it would nest the wait; allowing it costs one ad.
        guard !isDeciding else { return ["cacheable": false] }

        let url = details["url"] as? String ?? ""
        let type = details["type"] as? String ?? "other"
        let interested = Set(
            listeners.values.filter { $0.matches(url: url, type: type) }.map(\.extensionID)
        ).filter { !isMuted($0) }
        guard !interested.isEmpty else { return ["cacheable": true] }

        isDeciding = true
        defer { isDeciding = false }

        let id = nextRequestID
        nextRequestID &+= 1
        outstanding.insert(id)
        defer {
            outstanding.remove(id)
            answers.removeValue(forKey: id)
        }

        var asked = 0
        for extensionID in interested {
            guard let port = ports[extensionID], !port.isDisconnected else { continue }
            port.sendMessage(["op": "decide", "id": id, "details": details], completionHandler: nil)
            asked += 1
        }
        guard asked > 0 else { return ["cacheable": true] }

        let start = CFAbsoluteTimeGetCurrent()
        let deadline = start + Self.timeout
        // The extension's reply arrives as a main-queue block, so the run loop
        // has to keep turning. Default mode and not the common modes: event
        // tracking stays out, which keeps a mouse drag from re-entering here.
        while answers[id] == nil, CFAbsoluteTimeGetCurrent() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.002, true)
        }

        guard let answer = answers[id] else {
            Self.log.debug("webRequest listener timed out for \(url, privacy: .private)")
            noteTimeout(for: interested)
            return ["cacheable": false]
        }
        for extensionID in interested { consecutiveTimeouts.removeValue(forKey: extensionID) }
        record(latency: (CFAbsoluteTimeGetCurrent() - start) * 1000)

        var verdict: [String: Any] = ["cacheable": true]
        if answer["cancel"] as? Bool == true {
            verdict["cancel"] = true
        } else if let redirect = answer["redirectUrl"] as? String, !redirect.isEmpty {
            verdict["redirectUrl"] = redirect
        }
        return verdict
    }

    /// Which extension failed to answer is unknowable: the reply carries the
    /// request id, not a sender. Asking two blocking extensions at once is rare
    /// enough that charging the timeout to all of them is the honest simple
    /// reading, and a single answer clears every one of their counters.
    private func noteTimeout(for extensionIDs: Set<String>) {
        var muted = false
        for extensionID in extensionIDs {
            let count = (consecutiveTimeouts[extensionID] ?? 0) + 1
            consecutiveTimeouts[extensionID] = count
            guard count >= Self.timeoutsBeforeMuting else { continue }
            consecutiveTimeouts[extensionID] = 0
            mutedUntil[extensionID] = Date().addingTimeInterval(Self.muteDuration)
            muted = true
            Self.log.error("\(extensionID, privacy: .public) stopped answering; muted for \(Self.muteDuration)s")
        }
        guard muted else { return }
        // Stops the injected bundle asking at all while nothing can answer.
        writeState()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.muteDuration))
            self?.writeState()
        }
    }

    private func record(latency: Double) {
        latencies.append(latency)
        if latencies.count > 500 { latencies.removeFirst(latencies.count - 500) }
    }

    // MARK: - State

    /// Tells live web processes whether asking is worth the IPC. The bundle drops
    /// its cached verdicts on every push, since a new set of listeners may decide
    /// differently.
    private func writeState() {
        AuraWebBundle.webRequestStateDidChange()
    }
}

/// A `webRequest` filter's URL pattern.
///
/// Chrome's match-pattern grammar is scheme://host/path with `*` as the only
/// wildcard, so it converts to a regular expression exactly rather than by
/// approximation.
struct MatchPattern {
    private let expression: NSRegularExpression

    init?(_ pattern: String) {
        let source: String
        if pattern == "<all_urls>" {
            source = "^(https?|wss?|ftp|file|data):"
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
                .replacingOccurrences(of: "\\*", with: ".*")
            // A leading `*://` means any scheme, not any prefix. Left as `.*` it
            // would also match a URL that merely contains the pattern later on.
            source = "^" + escaped.replacingOccurrences(
                of: "^\\.\\*:", with: "[a-z]+:", options: .regularExpression
            ) + "$"
        }
        guard let expression = try? NSRegularExpression(pattern: source) else { return nil }
        self.expression = expression
    }

    func matches(_ url: String) -> Bool {
        expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
}
