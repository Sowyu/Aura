import Foundation
import os
@preconcurrency import WebKit

/// Host-side wiring for the WebKit injected bundle that runs Aura's synchronous,
/// per-subresource request filter inside the WebContent process.
///
/// Enabling this makes WebKit launch `com.apple.WebKit.WebContent.Development`
/// instead of `com.apple.WebKit.WebContent`, because
/// `WebProcessProxy::shouldAllowNonValidInjectedCode()` returns true for a
/// non-platform binary with a non-empty injected bundle path outside /System.
/// The Development service ships with library validation off, which is what
/// lets a third-party bundle be dlopen'd at all. No entitlement changes.
///
/// The bundle loads straight out of `Aura.app/Contents/PlugIns`. It used to be
/// copied into Application Support so the rule file could sit inside it, but a
/// file written into a signed bundle breaks its seal and Gatekeeper then shows
/// "Aura is damaged" on every launch. Rules and the webRequest flag now travel
/// over the bundle's synchronous message channel instead.
enum AuraWebBundle {
    private static let log = Logger(subsystem: "com.aurabrowser.app", category: "webbundle")
    private static let bundleName = "AuraWebBundle.wkbundle"

    /// `AURA_WEB_BUNDLE=0` / `=1` overrides the user setting either way.
    /// Read from `UserDefaults` rather than `SettingsStore` because pages are
    /// built off the main actor.
    static var isEnabled: Bool {
        if let override = ProcessInfo.processInfo.environment["AURA_WEB_BUNDLE"] {
            return override != "0"
        }
        return UserDefaults.standard.object(forKey: SettingsStore.nativeRequestBlockingEnabledKey) as? Bool ?? true
    }

    /// `Aura.app/Contents/PlugIns/AuraWebBundle.wkbundle`, the bundle WebKit loads.
    static let builtInBundleURL: URL? = Bundle.main.builtInPlugInsURL?.appendingPathComponent(bundleName)

    /// `Application Support/Aura/NativeBlocking/rules-v1.json`: where the host keeps
    /// the compiled native rules between launches. Served to the bundle on request.
    static let rulesFileURL: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Aura", isDirectory: true)
        .appendingPathComponent("NativeBlocking", isDirectory: true)
        .appendingPathComponent(AuraBlockRulesFileName)

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

    /// Answers the bundle's synchronous messages: rule sync on page creation, the
    /// webRequest active flag, and block/allow questions out of `WebRequestBroker`.
    /// Called once, right after the pool is built, because the client is per-pool.
    private static func installMessageHandler(on pool: WKProcessPool) {
        let installed = AuraSetInjectedBundleMessageHandler(pool) { name, body in
            // WebKit delivers injected-bundle messages on the main thread; the
            // guard is there so a future change to that lands as an allow
            // rather than a crash.
            guard Thread.isMainThread else { return nil }
            switch name {
            case AuraBlockRulesMessageName:
                return rulesDocument(ifNewerThan: body)
            case AuraWebRequestStateMessageName:
                return webRequestState
            default:
                guard #available(macOS 15.4, *) else { return nil }
                return MainActor.assumeIsolated { WebRequestBroker.shared.handle(name: name, body: body) }
            }
        }
        if !installed {
            log.error("injected-bundle message client unavailable; native blocking disabled")
        }
    }

    /// Points `configuration` at the injected-bundle process pool. No-op when disabled.
    static func apply(to configuration: WKWebViewConfiguration) {
        guard isEnabled, let processPool else { return }
        configuration.processPool = processPool
    }

    // MARK: - Rules

    private struct CachedRules {
        var modified: Date?
        var size: UInt64
        var revision: String
        var document: String
    }

    nonisolated(unsafe) private static var cachedRules = CachedRules(modified: nil, size: 0, revision: "", document: "{}")

    /// The rule document when its revision differs from `revision`, nil otherwise.
    /// One stat per call; the file is re-read only when it changed on disk. A
    /// missing file (native blocking off) reads as the empty document.
    private static func rulesDocument(ifNewerThan revision: String) -> String? {
        guard let rulesFileURL else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: rulesFileURL.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if attributes == nil {
            cachedRules = CachedRules(modified: nil, size: 0, revision: "", document: "{}")
        } else if modified != cachedRules.modified || size != cachedRules.size {
            guard let data = try? Data(contentsOf: rulesFileURL),
                  let document = String(data: data, encoding: .utf8)
            else { return nil }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            cachedRules = CachedRules(
                modified: modified,
                size: size,
                revision: root?["rev"] as? String ?? "",
                document: document
            )
        }
        return cachedRules.revision == revision ? nil : cachedRules.document
    }

    /// Pushes the freshly written document to every live web process, so open
    /// pages pick up a rebuild without waiting for the next page creation.
    static func rulesDidChange() {
        guard let livePool else { return }
        DispatchQueue.main.async {
            guard let document = rulesDocument(ifNewerThan: "\u{0}") else { return }
            AuraPostMessageToInjectedBundle(livePool, AuraBlockRulesMessageName, document)
        }
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
