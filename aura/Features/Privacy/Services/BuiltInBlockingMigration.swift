import Foundation
@preconcurrency import WebKit

/// One-time cleanup for profiles that ran Aura's own filter-list blocking.
///
/// uBlock Origin ships preinstalled and does the same job from inside the page,
/// so the built-in layer was deleted rather than switched off. What a returning
/// user still has on disk is the leftovers: downloaded lists, compiled
/// `WKContentRuleList` artifacts (tens of megabytes), the native rule file, and
/// the defaults keys that pointed at them. This drops all of it once.
///
/// The flag is set before the work, not after, so a run that fails halfway does
/// not repeat on every launch. Anything missed is inert.
enum BuiltInBlockingMigration {
    static let migratedKey = "privacy.builtInBlocking.migratedToUBO"

    /// Identifier prefix the old compile pipeline gave every list it compiled.
    private static let legacyRuleListPrefix = "com.orabrowser.adblock"

    private static let legacyDefaultsKeys = [
        "settings.tracking.adBlocking",
        "settings.adBlock.filterLists",
        "privacy.advancedBlocking.enabled",
        "privacy.advancedBlocking.disabledHosts",
        "privacy.nativeRequestBlocking.enabled"
    ]

    /// `Application Support/Aura/…` folders the old pipeline wrote into.
    private static let legacyDirectoryNames = ["ContentBlockers", "NativeBlocking"]

    /// Returns true when this call did the migration, false when it had already run.
    @discardableResult
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        supportDirectory: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Aura", isDirectory: true)
    ) -> Bool {
        guard !defaults.bool(forKey: migratedKey) else { return false }
        defaults.set(true, forKey: migratedKey)

        for key in legacyDefaultsKeys {
            defaults.removeObject(forKey: key)
        }

        // Per-space privacy blobs are left alone: `SpacePrivacySettings` ignores
        // the `adBlock` member it no longer has a field for.
        if let supportDirectory {
            for name in legacyDirectoryNames {
                try? FileManager.default.removeItem(
                    at: supportDirectory.appendingPathComponent(name, isDirectory: true)
                )
            }
        }

        removeCompiledRuleLists()
        return true
    }

    /// WebKit keeps compiled rule lists in its own store, well away from the
    /// artifacts above, so they have to be dropped through its API.
    private static func removeCompiledRuleLists() {
        guard let store = WKContentRuleListStore.default() else { return }
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for identifier in identifiers ?? [] where identifier.hasPrefix(legacyRuleListPrefix) {
                store.removeContentRuleList(forIdentifier: identifier) { _ in }
            }
        }
    }
}
