import Foundation
import os
@preconcurrency import WebKit

/// Host-side wiring for the WebKit injected bundle that lets an extension's
/// blocking `webRequest` listener answer synchronously, inside the WebContent
/// process, before the request reaches the network.
///
/// Enabling this makes WebKit launch `com.apple.WebKit.WebContent.Development`
/// instead of `com.apple.WebKit.WebContent`, because
/// `WebProcessProxy::shouldAllowNonValidInjectedCode()` returns true for a
/// non-platform binary with a non-empty injected bundle path outside /System.
/// The Development service ships with library validation off, which is what
/// lets a third-party bundle be dlopen'd at all. No entitlement changes.
///
/// The bundle loads straight out of `Aura.app/Contents/PlugIns`. Nothing is
/// ever written into it: a file written into a signed bundle breaks its seal
/// and Gatekeeper then shows "Aura is damaged" on every launch. The webRequest
/// flag travels over the bundle's synchronous message channel instead.
enum AuraWebBundle {
    private static let log = Logger(subsystem: "com.aurabrowser.app", category: "webbundle")
    private static let bundleName = "AuraWebBundle.wkbundle"

    /// Opt-in (Settings → Privacy). It is the only channel a blocking `webRequest`
    /// listener has, but hosting a bundle moves pages to WebKit's Development
    /// WebContent service, which cannot hold a foreground assertion and gets its
    /// layers purged after first paint. `AURA_WEB_BUNDLE=1/0` overrides for a session.
    ///
    /// Read once: a page put on the injected-bundle pool cannot be taken off it,
    /// so flipping the setting mid-session would only split the tabs in two.
    private static let isConfigured: Bool = {
        if let override = ProcessInfo.processInfo.environment["AURA_WEB_BUNDLE"] { return override != "0" }
        return SettingsStore.shared.extensionRequestBlocking
    }()

    /// Whether a new page should be put on the injected-bundle pool. The health
    /// probe can take this off mid-session, which is the one direction that is
    /// safe: pages already on the pool keep working, and every page created
    /// afterwards goes back to the ordinary WebContent service.
    static var isEnabled: Bool { isConfigured && !SettingsStore.shared.requestBlockingUnavailable }

    /// `Aura.app/Contents/PlugIns/AuraWebBundle.wkbundle`, the bundle WebKit loads.
    static let builtInBundleURL: URL? = Bundle.main.builtInPlugInsURL?.appendingPathComponent(bundleName)

    /// The shared injected-bundle process pool, or nil if the bundle is missing
    /// or the private API went away. Created once per process.
    static let processPool: WKProcessPool? = {
        guard let builtInBundleURL, FileManager.default.fileExists(atPath: builtInBundleURL.path) else {
            log.error("injected bundle missing at \(builtInBundleURL?.path ?? "nil", privacy: .public)")
            return nil
        }
        guard let pool = AuraMakeInjectedBundleProcessPool(builtInBundleURL) else {
            log.error("_WKProcessPoolConfiguration unavailable; injected bundle disabled")
            return nil
        }
        log.info("injected bundle process pool created for \(builtInBundleURL.path, privacy: .public)")
        installMessageHandler(on: pool)
        livePool = pool
        return pool
    }()

    /// Set once `processPool` exists, so pushes never force the pool into being.
    nonisolated(unsafe) private static var livePool: WKProcessPool?

    /// Answers the bundle's synchronous messages: the webRequest active flag and
    /// the block/allow questions `WebRequestBroker` handles.
    /// Called once, right after the pool is built, because the client is per-pool.
    private static func installMessageHandler(on pool: WKProcessPool) {
        let installed = AuraSetInjectedBundleMessageHandler(pool) { name, body in
            // WebKit delivers injected-bundle messages on the main thread; the
            // guard is there so a future change to that lands as an allow
            // rather than a crash.
            guard Thread.isMainThread else { return nil }
            noteBundleReplied()
            switch name {
            case AuraWebRequestStateMessageName:
                return webRequestState
            default:
                guard #available(macOS 15.4, *) else { return nil }
                return MainActor.assumeIsolated { WebRequestBroker.shared.handle(name: name, body: body) }
            }
        }
        if !installed {
            log.error("injected-bundle message client unavailable; blocking webRequest disabled")
        }
    }

    /// Points `configuration` at the injected-bundle process pool. No-op when disabled.
    static func apply(to configuration: WKWebViewConfiguration) {
        guard isEnabled, let processPool else { return }
        configuration.processPool = processPool
    }

    // MARK: - Health

    /// True once the injected bundle has said anything at all this session.
    ///
    /// Every message from it travels the whole private-API stack: the bundle was
    /// dlopen'd by a Development WebContent process, `WKBundlePostSynchronousMessage`
    /// reached the UI process, and the injected-bundle client transcribed in
    /// `AuraWebBundleSupport.m` was called. Nothing else needs checking.
    private(set) nonisolated(unsafe) static var didHearFromBundle = false

    /// Called from the message handler on the main thread.
    static func noteBundleReplied() {
        didHearFromBundle = true
    }

    /// Takes blocking `webRequest` off for the rest of this session.
    ///
    /// The stored preference is deliberately left alone. A half-changed OS build
    /// is what this is for, and the next one may well put the stack back; a
    /// setting the app switched off behind the user's back would never switch
    /// itself on again.
    ///
    /// `reason` is shown to the user in Settings > Privacy, so it is written as a
    /// sentence rather than as a log line.
    @MainActor
    static func markUnavailable(_ reason: String) {
        guard !SettingsStore.shared.requestBlockingUnavailable else { return }
        log.error("blocking webRequest unavailable: \(reason, privacy: .public)")
        SettingsStore.shared.requestBlockingUnavailable = true
        SettingsStore.shared.requestBlockingUnavailableReason = reason
        // uBO Lite comes back on the spot. The session it was switched off for has just
        // turned out to be one where full uBlock Origin cannot block anything.
        BundledExtensions.applyBlockingPlan()
    }

    /// Round trip through the whole private-API stack, once per launch.
    ///
    /// The feature rests on four transcribed private symbols and on WebKit
    /// hosting pages in its Development WebContent service. Any of them can go
    /// away in an OS update, and the symptom is subtle: loads that stall for the
    /// broker's timeout and extensions that quietly stop blocking.
    ///
    /// Two stages, because the cheap one usually settles it. Every page creation
    /// makes the bundle pull the active flag over the same path, so ordinary
    /// traffic is the probe whenever there is any. Only when none arrives does a
    /// throwaway page get made to force one, which is what tells a broken stack
    /// apart from a launch where no tab ever reached a web process.
    ///
    /// A third stage runs only for the users who switched full uBlock Origin on:
    /// a stack that answers messages can still fail to keep pages on screen, and
    /// that failure is what the Development WebContent service is known for. See
    /// `AuraWebBundle.PaintProbe`.
    ///
    /// Returns true when the bundle answered and pages still paint, or when there
    /// was nothing to probe.
    @MainActor
    @discardableResult
    static func probe(timeout: TimeInterval = 3) async -> Bool {
        guard isEnabled, let processPool else { return true }
        guard await answersMessages(within: timeout, pool: processPool) else { return false }
        guard SettingsStore.shared.extensionFullAdBlocking else { return true }

        switch await PaintProbe.run(pool: processPool) {
        case .blank:
            markUnavailable("Pages stopped painting when Aura checked at launch.")
            return false
        case .painted, .inconclusive:
            return true
        }
    }

    /// Stage one and two: anything the bundle says, or a throwaway page to make it
    /// say something. Marks the stack unavailable itself, so the caller only has to
    /// stop.
    @MainActor
    private static func answersMessages(within timeout: TimeInterval, pool: WKProcessPool) async -> Bool {
        if await heardFromBundle(within: timeout) { return true }

        guard let blank = URL(string: "about:blank") else { return true }
        let configuration = WKWebViewConfiguration()
        configuration.processPool = pool
        // Held in a static across the wait: a web view released mid-load takes
        // its web process with it, and nothing would be left to answer.
        probeWebView = WKWebView(frame: .zero, configuration: configuration)
        probeWebView?.load(URLRequest(url: blank))
        let answered = await heardFromBundle(within: timeout)
        probeWebView?.stopLoading()
        probeWebView = nil

        guard answered else {
            markUnavailable("The injected bundle did not answer when Aura checked at launch.")
            return false
        }
        log.info("injected bundle answered the startup probe")
        return true
    }

    private static func heardFromBundle(within timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !didHearFromBundle, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return didHearFromBundle
    }

    /// Alive only for the duration of `probe`.
    @MainActor private static var probeWebView: WKWebView?

    // MARK: - webRequest state

    /// "0", "1", or "3": a bit mask the bundle reads as active plus wants-headers. The
    /// two older values still mean what they meant before headers existed.
    private static var webRequestState: String {
        guard #available(macOS 15.4, *) else { return "0" }
        return MainActor.assumeIsolated { WebRequestBroker.shared.stateFlags }
    }

    /// Pushes the current flag to every live web process. Processes created later
    /// pull it themselves on page creation.
    @MainActor
    static func webRequestStateDidChange() {
        guard let livePool else { return }
        AuraPostMessageToInjectedBundle(livePool, AuraWebRequestStateMessageName, webRequestState)
    }
}
