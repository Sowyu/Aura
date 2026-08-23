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
/// extension answers or `timeout` runs out. What keeps that bounded is the
/// deadline, the muting of an extension that stopped answering, and
/// `WebRequestAskGate` capping how many asks may be parked at once. Everything
/// else the bundle does for itself: it never asks at all unless `isActive` was
/// pushed to it, and it caches answers this class marks cacheable.
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

        /// `onHeadersReceived` is deliberately absent: the injected bundle sees a
        /// request on its way out and never sees the response, so a listener on it
        /// could only be answered with a lie. The shim keeps those observe-only.
        static let answerableEvents: Set<String> = ["onBeforeRequest", "onBeforeSendHeaders"]

        func matches(url: String, type: String) -> Bool {
            guard Self.answerableEvents.contains(event) else { return false }
            if !types.isEmpty, !types.contains(type) { return false }
            if patterns.isEmpty { return true }
            return patterns.contains { $0.matches(url) }
        }
    }

    private var listeners: [Int: Listener] = [:]
    private var ports: [String: WKWebExtension.MessagePort] = [:]
    private var outstanding: Set<Int> = []
    /// Replies to the request in flight, keyed by request id and then by the
    /// extension that sent them. Keyed by sender because every asked extension
    /// gets a say, and because a silent one has to be identifiable to be muted.
    private var answers: [Int: [String: [String: Any]]] = [:]
    private var nextRequestID = 1
    private var gate = WebRequestAskGate()

    /// The reply for an ask nothing could answer: a timeout, or a gate that was
    /// full. Allowed, because a synchronous reply has nothing else it can say,
    /// and explicitly not cacheable so the bundle asks again next time instead
    /// of remembering an answer no extension gave.
    nonisolated static var unansweredVerdict: [String: Any] { ["cacheable": false] }

    /// The run loop mode the wait in `decide` spins in. Registering it as one of
    /// the main run loop's common modes brings along everything that was put
    /// there, which is what carries the reply: WebKit hands work to the main
    /// thread over a run loop source registered for the common modes, and the
    /// main dispatch queue is drained in any common mode as well. What it
    /// leaves behind is timers, since `Timer.scheduledTimer` registers for the
    /// default mode alone. That keeps TabManager's 60 s maintenance sweep from
    /// hibernating the very web view this decision belongs to, and
    /// DownloadManager's 0.1 s progress timers out of a 0.3 ms round trip.
    ///
    /// Narrowing it further is not possible from here, and it is worth writing
    /// down why. WebKit funnels every piece of main-thread work through one
    /// CFRunLoopSource registered for the common modes (`WTF::RunLoop::main()`),
    /// so the source that carries the extension's port reply is the same one
    /// that carries navigation delegate callbacks, script messages and download
    /// progress from every other tab. There is no separate message-port source
    /// to run on its own, no API to enumerate a mode's sources and drop the
    /// rest, and no way to receive the reply off the main thread: the port hands
    /// it to the main actor. So the reply cannot arrive without those callbacks
    /// arriving with it, and some of them call back into WebKit while this
    /// thread is parked inside a synchronous message reply.
    ///
    /// ponytail: the fix that removes the park altogether is to make the bundle
    /// poll. The host would answer the first ask immediately with "not yet",
    /// decide asynchronously on ordinary run loop turns, and let the web process
    /// re-ask a millisecond later, which keeps the stall in the web process
    /// where it belongs. That grows the reply's JSON shape, so it needs the
    /// bundle and the host shipped together.
    static let waitMode: CFRunLoopMode = {
        let mode = CFRunLoopMode("com.aurabrowser.webrequest" as CFString)
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), mode)
        return mode
    }()

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

    /// True while some live listener is on `onBeforeSendHeaders`. The bundle only pays
    /// for reading and shipping a request's headers when this is on.
    var wantsRequestHeaders: Bool {
        listeners.values.contains {
            $0.event == "onBeforeSendHeaders" && hasLivePort(for: $0.extensionID) && !isMuted($0.extensionID)
        }
    }

    /// What the bundle is told on `AuraWebRequestStateMessageName`, as a bit mask in a
    /// string: bit 0 is "some listener is registered", bit 1 is "send request headers
    /// with the ask". "0" and "1" mean exactly what they meant before this flag existed.
    var stateFlags: String {
        guard isActive else { return "0" }
        return wantsRequestHeaders ? "3" : "1"
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
    /// before any page loads, and starts the injected bundle's health probe.
    static func prepare() {
        _ = shared
        // Runs a round trip through the private-API stack and takes blocking off
        // for the session if it comes back empty. Detached from this call so the
        // first page is not held up by it.
        Task { await AuraWebBundle.probe() }
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
            answers[id, default: [:]][extensionID] = message
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
        let url = details["url"] as? String ?? ""
        let type = details["type"] as? String ?? "other"
        let interested = Set(
            listeners.values.filter { $0.matches(url: url, type: type) }.map(\.extensionID)
        ).filter { !isMuted($0) }
        // Costs no wait, so it never takes a slot in the gate.
        guard !interested.isEmpty else { return ["cacheable": true] }

        // Past the cap this is the one thing left to do. Everything up to it is
        // served, including asks that arrive while this one is parked.
        guard gate.admit() else {
            Self.log.error("\(WebRequestAskGate.maxDepth) asks already parked; allowing \(url, privacy: .private)")
            return Self.unansweredVerdict
        }
        defer { gate.release() }

        let id = nextRequestID
        nextRequestID &+= 1
        outstanding.insert(id)
        defer {
            outstanding.remove(id)
            answers.removeValue(forKey: id)
        }

        var asked: Set<String> = []
        for extensionID in interested {
            guard let port = ports[extensionID], !port.isDisconnected else { continue }
            port.sendMessage(["op": "decide", "id": id, "details": details], completionHandler: nil)
            asked.insert(extensionID)
        }
        guard !asked.isEmpty else { return ["cacheable": true] }

        let start = CFAbsoluteTimeGetCurrent()
        let deadline = start + Self.timeout
        // Every extension that was asked gets to answer, since a second one may
        // cancel what the first allowed. The replies land on this thread, so
        // the run loop has to keep turning; `waitMode` is what keeps it from
        // turning anything else.
        //
        // Replies for every parked ask are filed under their own id and any spin
        // delivers all of them, so nested waits overlap in real time rather than
        // adding up: the deepest frame's turn of the run loop is also the
        // outermost frame's.
        while (answers[id]?.count ?? 0) < asked.count, CFAbsoluteTimeGetCurrent() < deadline {
            CFRunLoopRunInMode(Self.waitMode, 0.002, true)
        }

        let replies = answers[id] ?? [:]
        let silent = asked.subtracting(replies.keys)
        guard !replies.isEmpty else {
            Self.log.debug("webRequest listener timed out for \(url, privacy: .private)")
            noteTimeout(for: silent)
            return Self.unansweredVerdict
        }
        for extensionID in replies.keys { consecutiveTimeouts.removeValue(forKey: extensionID) }
        noteTimeout(for: silent)
        record(latency: (CFAbsoluteTimeGetCurrent() - start) * 1000)

        // Sorted so two extensions answering with different redirects always
        // pick the same winner.
        let ordered = replies.sorted { $0.key < $1.key }.map(\.value)
        let merged = WebRequestVerdict.merge(ordered.map { WebRequestVerdict(message: $0) })
        var verdict = merged.payload
        // Headers only matter to a request that is still going out as itself. A
        // redirect builds a fresh request from the URL alone, and a cancel has
        // nothing left to send.
        let patch = merged == .allow
            ? WebRequestHeaderPatch.merge(ordered.map { WebRequestHeaderPatch(message: $0) })
            : WebRequestHeaderPatch()
        verdict.merge(patch.payload) { current, _ in current }
        // A verdict that only part of the extensions contributed to must not be
        // remembered by the bundle: the silent one may answer next time. Neither is a
        // header patch: the listener was handed this request's own headers, and the
        // next request with the same URL carries different ones.
        verdict["cacheable"] = silent.isEmpty && patch.isEmpty
        return verdict
    }

    /// Charged only to the extensions that stayed silent, since replies are
    /// filed under their sender. Any answer clears that extension's counter.
    private func noteTimeout(for extensionIDs: Set<String>) {
        guard !extensionIDs.isEmpty else { return }
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

/// How many asks may be parked on the main thread at once.
///
/// An ask that arrives while another is being decided cannot be deferred until
/// the first one finishes. It lands as a nested call on the main thread, sent by
/// a second web process parked in its own synchronous message, and stack frames
/// unwind in the order they were pushed: the newest ask has to produce a verdict
/// before the one under it can resume. Waving it through was the old answer, and
/// it made blocking probabilistic. A page fires its subresources in parallel, so
/// under the load where blocking matters most, most requests were admitted
/// without any extension seeing them.
///
/// So each one is served where it lands, and this is what a pathological page
/// cannot get past: every parked ask is a stack frame and a share of the main
/// thread. Past `maxDepth` the newest is allowed and marked non-cacheable.
///
/// ponytail: 32 nested asks that each time out is 32 x `timeout` of stalled main
/// thread in the worst case. In practice they overlap (one spin delivers every
/// parked ask's reply) and an extension that stops answering is muted after
/// three timeouts. Lower the cap if that mute path ever regresses.
struct WebRequestAskGate {
    static let maxDepth = 32

    private(set) var depth = 0

    /// True while at least one decision is parked.
    var isBusy: Bool { depth > 0 }

    /// Takes a slot, or returns false when the cap is reached. A refused ask
    /// takes no slot, so a page hammering an already-full gate cannot keep it
    /// full by itself.
    mutating func admit() -> Bool {
        guard depth < Self.maxDepth else { return false }
        depth += 1
        return true
    }

    mutating func release() {
        guard depth > 0 else { return }
        depth -= 1
    }
}

/// What one extension answered to a blocking `webRequest` ask.
enum WebRequestVerdict: Equatable {
    case allow
    case cancel
    case redirect(String)

    /// A `verdict` message as the shim sends it.
    init(message: [String: Any]) {
        if message["cancel"] as? Bool == true {
            self = .cancel
        } else if let redirect = message["redirectUrl"] as? String, !redirect.isEmpty {
            self = .redirect(redirect)
        } else {
            self = .allow
        }
    }

    /// Chrome's rule when several extensions answer the same request: a cancel
    /// from any of them wins, and a redirect applies only if nobody cancelled.
    /// Two redirects are a genuine conflict Chrome resolves by install order,
    /// so the first answer given here wins and the caller decides the order.
    static func merge(_ answers: [WebRequestVerdict]) -> WebRequestVerdict {
        if answers.contains(.cancel) { return .cancel }
        for answer in answers {
            if case .redirect = answer { return answer }
        }
        return .allow
    }

    /// The half of the bundle's reply that names the action. `cacheable` is the
    /// broker's to add.
    var payload: [String: Any] {
        switch self {
        case .allow: return [:]
        case .cancel: return ["cancel": true]
        case let .redirect(url): return ["redirectUrl": url]
        }
    }
}

/// The header changes one extension asked for on `onBeforeSendHeaders`.
///
/// Chrome's API has the listener return the whole header array it wants sent, so the
/// shim does the diffing against the array it handed over and only the difference
/// travels: names to set, names to drop. The bundle applies that to the request it is
/// holding, which is the only shape that survives the C API (see
/// `ExtensionCompatibility.requestHeaderCeiling`).
struct WebRequestHeaderPatch: Equatable {
    /// Header name to value. Case is the extension's; HTTP header names are
    /// case-insensitive and NSMutableURLRequest folds them.
    var setHeaders: [String: String] = [:]
    /// Names to drop, lowercased so two extensions naming the same header differently
    /// still collide.
    var removedHeaders: Set<String> = []

    var isEmpty: Bool { setHeaders.isEmpty && removedHeaders.isEmpty }

    init() {}

    /// A `verdict` message as the shim sends it.
    init(message: [String: Any]) {
        if let headers = message["setHeaders"] as? [String: Any] {
            for (name, value) in headers {
                guard let text = value as? String else { continue }
                setHeaders[name] = text
            }
        }
        if let names = message["removeHeaders"] as? [String] {
            removedHeaders = Set(names.map { $0.lowercased() })
        }
    }

    /// Same conflict rule the redirect merge uses: the caller passes answers in a
    /// stable order and the first one to name a header wins. Setting a header outranks
    /// removing it, because a listener that set a value said what it wants sent.
    static func merge(_ patches: [WebRequestHeaderPatch]) -> WebRequestHeaderPatch {
        var merged = WebRequestHeaderPatch()
        for patch in patches {
            for (name, value) in patch.setHeaders where merged.setHeaders[name] == nil {
                merged.setHeaders[name] = value
            }
            merged.removedHeaders.formUnion(patch.removedHeaders)
        }
        merged.removedHeaders.subtract(merged.setHeaders.keys.map { $0.lowercased() })
        return merged
    }

    /// The half of the bundle's reply that carries headers. Empty when there is
    /// nothing to change, so an ordinary allow stays the same bytes it always was.
    var payload: [String: Any] {
        var payload: [String: Any] = [:]
        if !setHeaders.isEmpty { payload["setHeaders"] = setHeaders }
        if !removedHeaders.isEmpty { payload["removeHeaders"] = removedHeaders.sorted() }
        return payload
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
            source = "^(?i:(https?|wss?|ftp|file|data):)"
        } else {
            // Scheme and host are case-insensitive, the path is not, so the
            // pattern splits at the first slash after the authority and only
            // the left half is folded. A host wildcard stops at that slash:
            // `*` there means any label, never the rest of the URL.
            let afterScheme = pattern.range(of: "://")?.upperBound ?? pattern.startIndex
            let pathStart = pattern[afterScheme...].firstIndex(of: "/") ?? pattern.endIndex
            let authority = Self.escape(String(pattern[..<pathStart]), wildcard: "[^/]*")
            let path = Self.escape(String(pattern[pathStart...]), wildcard: ".*")
            // A leading `*://` means any scheme, not any prefix. Left as a
            // wildcard it would also match a URL that merely contains the
            // pattern later on.
            let folded = authority.replacingOccurrences(
                of: "^\\[\\^/\\]\\*:", with: "[a-zA-Z]+:", options: .regularExpression
            )
            source = "^(?i:" + folded + ")" + path + "$"
        }
        guard let expression = try? NSRegularExpression(pattern: source) else { return nil }
        self.expression = expression
    }

    private static func escape(_ part: String, wildcard: String) -> String {
        NSRegularExpression.escapedPattern(for: part).replacingOccurrences(of: "\\*", with: wildcard)
    }

    func matches(_ url: String) -> Bool {
        expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
}
