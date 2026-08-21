import Foundation
import OSLog

private let logger = AuraLog.category("LegacyDataMigrator")

/// One-shot copy of the pre-rename data folder into the renamed one.
///
/// The rename moved two things: the Application Support folder (`Ora` to `Aura`) and,
/// for sandboxed builds, the whole container (`com.orabrowser.app` to `com.aurabrowser.app`).
/// Everything the browser persists lives under that folder, so copying the folder
/// wholesale is the migration: the SwiftData store with its `-shm`/`-wal` siblings,
/// unpacked extensions, and compiled ad-block artifacts.
///
/// Copies rather than moves, so a user who downgrades still has working data.
struct LegacyDataMigrator {
    static let legacyBundleIdentifier = "com.orabrowser.app"
    static let legacyFolderName = "Ora"
    static let folderName = "Aura"
    static let defaultsMigrationKey = "legacyDefaultsMigratedFromOra"

    private static let markerName = ".migrated-from-ora"

    let oldRoot: URL
    let newRoot: URL
    let fileManager: FileManager

    init(oldRoot: URL, newRoot: URL, fileManager: FileManager = .default) {
        self.oldRoot = oldRoot
        self.newRoot = newRoot
        self.fileManager = fileManager
    }

    // MARK: - Launch entry point

    /// Call once at launch, before anything opens the SwiftData store.
    static func runIfNeeded() {
        let appSupport = URL.applicationSupportDirectory
        let newRoot = appSupport.appending(path: folderName)

        for oldRoot in legacyRoots(appSupport: appSupport) {
            do {
                if try LegacyDataMigrator(oldRoot: oldRoot, newRoot: newRoot).migrate() {
                    logger.notice("Migrated data from \(oldRoot.path, privacy: .public)")
                    break
                }
            } catch {
                logger.error("Migration from \(oldRoot.path, privacy: .public) failed: \(error.localizedDescription)")
            }
        }

        migrateUserDefaults()
    }

    /// Where the old data can be: this container's own Application Support first, then the
    /// pre-rename sandbox container. The sandbox usually denies the second one; that read is
    /// best effort and its failure is logged, not fatal.
    static func legacyRoots(appSupport: URL) -> [URL] {
        let local = appSupport.appending(path: legacyFolderName)
        let container = realHomeDirectory
            .appending(path: "Library/Containers/\(legacyBundleIdentifier)")
            .appending(path: "Data/Library/Application Support/\(legacyFolderName)")
        return container.standardizedFileURL == local.standardizedFileURL ? [local] : [local, container]
    }

    /// `FileManager.homeDirectoryForCurrentUser` points inside the sandbox container, so the
    /// old container is only reachable through the passwd entry.
    private static var realHomeDirectory: URL {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir))
    }

    // MARK: - Files

    /// Copies `oldRoot`'s contents into `newRoot`. Returns true when something was copied.
    /// Runs at most once: after any attempt, a marker file inside `newRoot` shuts it off.
    @discardableResult
    func migrate() throws -> Bool {
        let marker = newRoot.appending(path: Self.markerName)
        if fileManager.fileExists(atPath: marker.path) { return false }
        guard fileManager.fileExists(atPath: oldRoot.path) else { return false }

        // A populated new folder means this install has already been used. Never clobber it.
        guard try isEffectivelyEmpty(newRoot) else {
            try writeMarker(marker)
            return false
        }

        try fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)
        var copied = false
        for item in try fileManager.contentsOfDirectory(at: oldRoot, includingPropertiesForKeys: nil) {
            let destination = newRoot.appending(path: item.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) { continue }
            do {
                try fileManager.copyItem(at: item, to: destination)
                copied = true
            } catch {
                let name = item.lastPathComponent
                logger.error("Could not copy \(name, privacy: .public): \(error.localizedDescription)")
            }
        }
        try writeMarker(marker)
        return copied
    }

    private func isEffectivelyEmpty(_ url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        let contents = try fileManager.contentsOfDirectory(atPath: url.path)
        return contents.allSatisfy { $0 == Self.markerName || $0 == ".DS_Store" }
    }

    private func writeMarker(_ marker: URL) throws {
        try fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: marker)
    }

    // MARK: - Preferences

    /// Copies the old bundle id's defaults into the current suite, skipping keys that
    /// already have a value. Sandboxed builds cannot read another container's preferences,
    /// so an empty read is expected and only logged.
    static func migrateUserDefaults(
        suiteName: String = legacyBundleIdentifier,
        into defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: defaultsMigrationKey) else { return }
        defer { defaults.set(true, forKey: defaultsMigrationKey) }

        guard let legacy = UserDefaults(suiteName: suiteName) else {
            logger.notice("No legacy defaults suite \(suiteName, privacy: .public); nothing to copy.")
            return
        }

        var copied = 0
        for (key, value) in legacy.dictionaryRepresentation()
            where !isSystemKey(key) && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        logger.notice("Copied \(copied) legacy preference(s) from \(suiteName, privacy: .public).")
    }

    /// A suite's dictionary also carries the global domain. Those keys belong to macOS.
    private static func isSystemKey(_ key: String) -> Bool {
        key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple.")
    }
}
