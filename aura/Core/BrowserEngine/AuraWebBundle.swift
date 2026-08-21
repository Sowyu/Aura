import Darwin
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
enum AuraWebBundle {
    private static let log = Logger(subsystem: "com.aurabrowser.app", category: "webbundle")
    private static let bundleName = "AuraWebBundle.wkbundle"

    private static func removeQuarantine(under root: URL) {
        let keys = ["com.apple.quarantine", "com.apple.provenance"]
        var paths = [root.path]
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            while let relative = walker.nextObject() as? String {
                paths.append(root.appendingPathComponent(relative).path)
            }
        }
        for path in paths {
            for key in keys { removexattr(path, key, XATTR_NOFOLLOW) }
        }
    }

    /// `AURA_WEB_BUNDLE=0` / `=1` overrides the user setting either way.
    /// Read from `UserDefaults` rather than `SettingsStore` because pages are
    /// built off the main actor.
    static var isEnabled: Bool {
        if let override = ProcessInfo.processInfo.environment["AURA_WEB_BUNDLE"] {
            return override != "0"
        }
        return UserDefaults.standard.object(forKey: SettingsStore.nativeRequestBlockingEnabledKey) as? Bool ?? true
    }

    /// `Aura.app/Contents/PlugIns/AuraWebBundle.wkbundle`.
    static let builtInBundleURL: URL? = Bundle.main.builtInPlugInsURL?.appendingPathComponent(bundleName)

    /// `Application Support/Aura/NativeBlocking/`.
    static let supportDirectoryURL: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Aura", isDirectory: true)
        .appendingPathComponent("NativeBlocking", isDirectory: true)

    /// The copy WebKit actually loads. The app bundle is read-only and signed, and
    /// the rule file has to sit inside whatever directory `injectedBundleURL`
    /// names: that path is the only sandbox extension the WebContent process gets.
    static let installedBundleURL: URL? = {
        guard let supportDirectoryURL else { return nil }
        return supportDirectoryURL.appendingPathComponent(bundleName)
    }()

    /// Where the host writes the compiled native rules and the bundle reads them.
    static let rulesFileURL: URL? = installedBundleURL?
        .appendingPathComponent("Contents/Resources", isDirectory: true)
        .appendingPathComponent(AuraBlockRulesFileName)

    /// The shared injected-bundle process pool, or nil if the bundle is missing
    /// or the private API went away. Created once per process.
    static let processPool: WKProcessPool? = {
        guard let installedURL = install() else { return nil }
        guard let pool = AuraMakeInjectedBundleProcessPool(installedURL) else {
            log.error("_WKProcessPoolConfiguration unavailable; injected bundle disabled")
            return nil
        }
        log.info("injected bundle process pool created for \(installedURL.path, privacy: .public)")
        installWebRequestHandler(on: pool)
        return pool
    }()

    /// Answers the bundle's synchronous block/allow questions out of
    /// `WebRequestBroker`. Called once, right after the pool is built, because
    /// the client is per-pool and the bundle starts asking as soon as an
    /// extension registers a blocking listener.
    private static func installWebRequestHandler(on pool: WKProcessPool) {
        guard #available(macOS 15.4, *) else { return }
        let installed = AuraSetInjectedBundleMessageHandler(pool) { name, body in
            // WebKit delivers injected-bundle messages on the main thread; the
            // guard is there so a future change to that lands as an allow
            // rather than a crash.
            guard Thread.isMainThread else { return nil }
            return MainActor.assumeIsolated { WebRequestBroker.shared.handle(name: name, body: body) }
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

    /// Copies the built bundle next to the rule file, refreshing the copy whenever
    /// the app ships a new one. Returns the copy's URL.
    @discardableResult
    static func install() -> URL? {
        guard let builtInBundleURL, let installedBundleURL, let rulesFileURL else { return nil }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: builtInBundleURL.path) else {
            log.error("injected bundle missing at \(builtInBundleURL.path, privacy: .public)")
            return nil
        }

        do {
            if isStale(installed: installedBundleURL, source: builtInBundleURL) {
                let rules = try? Data(contentsOf: rulesFileURL)
                try? fileManager.removeItem(at: installedBundleURL)
                try fileManager.createDirectory(
                    at: installedBundleURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: builtInBundleURL, to: installedBundleURL)
                // A browser's newly written files are quarantined. Gatekeeper then refuses
                // to let WebContent load the copy and shows "Aura is damaged" while the
                // app itself keeps running. The copy is our own signed code; unflag it.
                Self.removeQuarantine(under: installedBundleURL)
                try fileManager.createDirectory(
                    at: rulesFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if let rules { try? rules.write(to: rulesFileURL, options: .atomic) }
            }
            return installedBundleURL
        } catch {
            log.error("injected bundle install failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func isStale(installed: URL, source: URL) -> Bool {
        let executable = "Contents/MacOS/AuraWebBundle"
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let installedValues = try? installed.appendingPathComponent(executable)
            .resourceValues(forKeys: keys),
            let sourceValues = try? source.appendingPathComponent(executable).resourceValues(forKeys: keys)
        else {
            return true
        }
        return installedValues.fileSize != sourceValues.fileSize
            || installedValues.contentModificationDate != sourceValues.contentModificationDate
    }
}
