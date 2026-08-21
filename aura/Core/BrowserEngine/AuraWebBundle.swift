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
        return pool
    }()

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
