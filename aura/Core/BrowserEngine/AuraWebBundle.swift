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
    static let isEnabled: Bool = {
        if let override = ProcessInfo.processInfo.environment["AURA_WEB_BUNDLE"] { return override != "0" }
        return SettingsStore.shared.extensionRequestBlocking
    }()

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

    // MARK: - webRequest state

    private static var webRequestState: String {
        guard #available(macOS 15.4, *) else { return "0" }
        return MainActor.assumeIsolated { WebRequestBroker.shared.isActive ? "1" : "0" }
    }

    /// Pushes the current flag to every live web process. Processes created later
    /// pull it themselves on page creation.
    @MainActor
    static func webRequestStateDidChange() {
        guard let livePool else { return }
        AuraPostMessageToInjectedBundle(livePool, AuraWebRequestStateMessageName, webRequestState)
    }
}
