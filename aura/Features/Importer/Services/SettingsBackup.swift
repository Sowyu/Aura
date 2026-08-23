import Foundation

/// Every preference Aura owns, as one JSON file.
///
/// The point is moving a set-up Aura onto a second Mac, so the file has to survive a
/// round trip through `JSONSerialization` and still put back the exact values
/// `UserDefaults` held. Two of those values are awkward: settings stored as JSON blobs
/// (search engines, keyboard shortcuts, site permissions, extension consent) arrive as
/// `Data`, which JSON has no type for, and `Date` has no unambiguous JSON spelling
/// either. Rather than smuggling a marker into the values, the document keeps them in
/// separate maps and the importer knows which is which.
enum SettingsBackup {
    static let formatVersion = 1

    private enum Key {
        static let format = "format"
        static let application = "app"
        static let exportedAt = "exportedAt"
        static let values = "values"
        static let data = "data"
    }

    /// Keys that are Aura's on paper but must not travel.
    ///
    /// A security-scoped bookmark names a folder on the Mac that made it and resolves to
    /// nothing anywhere else, so importing one would leave downloads pointing at a path
    /// the sandbox has no grant for. The migration marker is a fact about this install,
    /// not a preference: copying it would tell a fresh install it had already migrated.
    /// The WebKit key is WebKit's own default, which Aura mirrors rather than owns.
    static let excludedKeys: Set<String> = [
        "downloads.folderBookmark",
        LegacyDataMigrator.defaultsMigrationKey,
        SettingsStore.webKitSpellCheckKey,
        SettingsStore.appleShowScrollBarsKey
    ]

    /// The same rule `LegacyDataMigrator` applies when it copies the pre-rename suite:
    /// a domain's dictionary also carries the global domain, and those keys belong to
    /// macOS. Restated here rather than shared because the migrator's copy is private to
    /// it, and `SettingsBackupTests` pins the two lists to the same answers.
    static func isSystemKey(_ key: String) -> Bool {
        key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple.")
    }

    /// True for a key whose value belongs in the export.
    static func isExportable(_ key: String) -> Bool {
        !isSystemKey(key) && !excludedKeys.contains(key)
    }

    // MARK: - Export

    static func export(from defaults: UserDefaults = .standard, now: Date = Date()) throws -> Data {
        var values: [String: Any] = [:]
        var blobs: [String: String] = [:]

        for (key, value) in defaults.dictionaryRepresentation() where isExportable(key) {
            if let data = value as? Data {
                blobs[key] = data.base64EncodedString()
            } else if JSONSerialization.isValidJSONObject([value]) {
                values[key] = value
            }
            // Anything else (a `Date`, an archived object) is dropped: no Aura setting
            // is stored that way, and guessing a spelling for one would import wrong.
        }

        let document: [String: Any] = [
            Key.format: formatVersion,
            Key.application: "Aura",
            Key.exportedAt: ISO8601DateFormatter().string(from: now),
            Key.values: values,
            Key.data: blobs
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Import

    /// Applies only the keys the file carries, and leaves everything else alone: an
    /// import is a merge, not a reset. Returns how many keys were written.
    @discardableResult
    static func apply(_ data: Data, to defaults: UserDefaults = .standard) throws -> Int {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsBackupError.notASettingsFile
        }
        guard let version = document[Key.format] as? Int else {
            throw SettingsBackupError.notASettingsFile
        }
        guard version <= formatVersion else {
            throw SettingsBackupError.newerFormat(version)
        }

        var applied = 0
        for (key, value) in document[Key.values] as? [String: Any] ?? [:] where isExportable(key) {
            defaults.set(value, forKey: key)
            applied += 1
        }
        for (key, encoded) in document[Key.data] as? [String: String] ?? [:] where isExportable(key) {
            guard let blob = Data(base64Encoded: encoded) else { continue }
            defaults.set(blob, forKey: key)
            applied += 1
        }
        return applied
    }
}

enum SettingsBackupError: LocalizedError {
    case notASettingsFile
    case newerFormat(Int)

    var errorDescription: String? {
        switch self {
        case .notASettingsFile:
            return "That file is not an Aura settings export."
        case let .newerFormat(version):
            return "That file was written by a newer version of Aura (format \(version))."
        }
    }
}
