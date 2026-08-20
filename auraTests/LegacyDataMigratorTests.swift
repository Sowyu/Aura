import Foundation
@testable import Aura
import Testing

@Suite("legacy data migration")
struct LegacyDataMigratorTests {
    private struct Layout {
        let root: URL
        let old: URL
        let new: URL
    }

    /// Builds `<temp>/Ora` with the shape a pre-rename install leaves behind.
    private func makeLegacyLayout() throws -> Layout {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "aura-migration-\(UUID().uuidString)")
        let old = root.appending(path: "Ora")
        let new = root.appending(path: "Aura")

        try fileManager.createDirectory(at: old.appending(path: "Extensions/demo"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: old.appending(path: "ContentBlockers"), withIntermediateDirectories: true)
        try Data("store".utf8).write(to: old.appending(path: "OraData.sqlite"))
        try Data("wal".utf8).write(to: old.appending(path: "OraData.sqlite-wal"))
        try Data("shm".utf8).write(to: old.appending(path: "OraData.sqlite-shm"))
        try Data("{}".utf8).write(to: old.appending(path: "Extensions/demo/manifest.json"))
        try Data("[]".utf8).write(to: old.appending(path: "ContentBlockers/easylist.json"))

        return Layout(root: root, old: old, new: new)
    }

    @Test("copies the old folder, then a second run does nothing")
    func copiesLegacyLayoutOnce() throws {
        let fileManager = FileManager.default
        let layout = try makeLegacyLayout()
        let (root, old, new) = (layout.root, layout.old, layout.new)
        defer { try? fileManager.removeItem(at: root) }

        let migrator = LegacyDataMigrator(oldRoot: old, newRoot: new)
        let copied = try migrator.migrate()
        #expect(copied)

        for relative in [
            "OraData.sqlite",
            "OraData.sqlite-wal",
            "OraData.sqlite-shm",
            "Extensions/demo/manifest.json",
            "ContentBlockers/easylist.json"
        ] {
            #expect(fileManager.fileExists(atPath: new.appending(path: relative).path), "missing \(relative)")
        }
        // Copied, not moved: the old install still works after a downgrade.
        #expect(fileManager.fileExists(atPath: old.appending(path: "OraData.sqlite").path))

        // Deleting migrated data must not bring it back on the next launch.
        try fileManager.removeItem(at: new.appending(path: "OraData.sqlite"))
        let secondRun = try migrator.migrate()
        #expect(!secondRun)
        #expect(!fileManager.fileExists(atPath: new.appending(path: "OraData.sqlite").path))
    }

    @Test("a new folder that already holds data is never overwritten")
    func doesNotClobberExistingData() throws {
        let fileManager = FileManager.default
        let layout = try makeLegacyLayout()
        let (root, old, new) = (layout.root, layout.old, layout.new)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("current".utf8).write(to: new.appending(path: "OraData.sqlite"))

        let copied = try LegacyDataMigrator(oldRoot: old, newRoot: new).migrate()
        #expect(!copied)

        let survived = try String(contentsOf: new.appending(path: "OraData.sqlite"), encoding: .utf8)
        #expect(survived == "current")
        #expect(!fileManager.fileExists(atPath: new.appending(path: "Extensions").path))
    }

    @Test("no legacy folder means nothing happens")
    func missingLegacyFolderIsANoOp() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "aura-migration-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let new = root.appending(path: "Aura")
        let copied = try LegacyDataMigrator(oldRoot: root.appending(path: "Ora"), newRoot: new).migrate()
        #expect(!copied)
        #expect(!fileManager.fileExists(atPath: new.path))
    }
}
