import Foundation
import Testing
import WebKit

@testable import Aura

/// uBlock Origin does the blocking now. These two guard the removal: a page must
/// not pay for a `WKContentRuleList` any more, and the cleanup of what the old
/// pipeline left on disk must happen exactly once.
struct BuiltInBlockingRemovalTests {
    // WebKit initialises itself on first touch and insists on the main thread.
    @Test @MainActor func freshConfigurationAttachesNoContentRuleLists() async {
        // What a new install gets. Anything non-empty here is a rule list WebKit
        // would compile and match on every request, on top of uBlock Origin.
        #expect(BrowserPrivacyService.shared.ruleListIdentifiers(for: SpacePrivacySettings()).isEmpty)

        let configuration = WKWebViewConfiguration()
        await withCheckedContinuation { continuation in
            BrowserPrivacyService.shared.prepareConfiguration(configuration, spaceID: UUID()) {
                continuation.resume()
            }
        }

        // The cookie policy still comes through; it costs no rule list.
        #expect(configuration.websiteDataStore.isPersistent)
    }

    @Test @MainActor func builtInBlockingMigrationRunsOnce() throws {
        let suiteName = "aura.tests.migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-migration-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: support)
        }

        let artifacts = support.appendingPathComponent("ContentBlockers", isDirectory: true)
        let nativeRules = support.appendingPathComponent("NativeBlocking", isDirectory: true)
        for directory in [artifacts, nativeRules] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("stale".utf8).write(to: directory.appendingPathComponent("leftover.json"))
        }
        defaults.set(true, forKey: "settings.tracking.adBlocking")
        defaults.set(["easylist"], forKey: "settings.adBlock.filterLists")

        #expect(BuiltInBlockingMigration.runIfNeeded(defaults: defaults, supportDirectory: support))
        #expect(defaults.bool(forKey: BuiltInBlockingMigration.migratedKey))
        #expect(defaults.object(forKey: "settings.tracking.adBlocking") == nil)
        #expect(defaults.object(forKey: "settings.adBlock.filterLists") == nil)
        #expect(!FileManager.default.fileExists(atPath: artifacts.path))
        #expect(!FileManager.default.fileExists(atPath: nativeRules.path))

        // Second launch: the flag is the whole point, so nothing runs again.
        #expect(BuiltInBlockingMigration.runIfNeeded(defaults: defaults, supportDirectory: support) == false)
    }
}
