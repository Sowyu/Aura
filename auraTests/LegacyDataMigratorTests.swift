import Foundation
@testable import Aura
import SwiftData
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

@Suite("schema migration")
struct SchemaMigrationTests {
    /// The pre-container graph, written by the V1 schema itself rather than by a binary
    /// store checked into the repo: the fixture is then always in step with the types
    /// the plan migrates from.
    private struct FixtureIDs {
        let space = UUID()
        let tab = UUID()
        let visit = UUID()
    }

    private func writeV1Store(at url: URL) throws -> FixtureIDs {
        let ids = FixtureIDs()
        try autoreleasepool {
            let schema = Schema(versionedSchema: AuraSchemaV1.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = ModelContext(container)
            let space = AuraSchemaV1.TabContainer(id: ids.space, name: "Old Space")
            context.insert(space)
            let tab = try AuraSchemaV1.Tab(
                id: ids.tab,
                url: #require(URL(string: "https://example.com/old")),
                title: "old tab",
                container: space,
                order: 1
            )
            context.insert(tab)
            let visit = try AuraSchemaV1.History(
                id: ids.visit,
                url: #require(URL(string: "https://example.com/visited")),
                title: "old visit",
                faviconURL: #require(URL(string: "https://example.com/favicon.ico")),
                container: space
            )
            context.insert(visit)
            try context.save()
        }
        return ids
    }

    @Test("a store written by the pre-container schema opens through the plan")
    func aV1StoreMigratesToV2() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "aura-schema-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let ids = try writeV1Store(at: root.appending(path: "OraData.sqlite"))

        let schema = Schema(versionedSchema: AuraSchemaV2.self)
        let migrated = try ModelContainer(
            for: schema,
            migrationPlan: AuraMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: root.appending(path: "OraData.sqlite"))
        )
        let context = ModelContext(migrated)

        let spaces = try context.fetch(FetchDescriptor<TabContainer>())
        #expect(spaces.map(\.id) == [ids.space])
        let tabs = try context.fetch(FetchDescriptor<Tab>())
        #expect(tabs.map(\.id) == [ids.tab])
        // The relationships the new entity added come back empty, which is what "no
        // container" means for a tab that predates them.
        #expect(tabs.first?.browsingContainer == nil)
        #expect(spaces.first?.defaultBrowsingContainer == nil)
        let containerCount = try context.fetchCount(FetchDescriptor<BrowsingContainer>())
        #expect(containerCount == 0)

        let visits = try context.fetch(FetchDescriptor<History>())
        #expect(visits.map(\.id) == [ids.visit])
        // Non-optional in V1, optional in V2, and the value survives the change.
        #expect(visits.first?.faviconURL?.absoluteString == "https://example.com/favicon.ico")
    }

    @Test("the plan names every schema its stages walk through")
    func theStagesCoverEverySchema() {
        #expect(AuraMigrationPlan.schemas.count == AuraMigrationPlan.stages.count + 1)
        #expect(AuraSchemaV1.versionIdentifier < AuraSchemaV2.versionIdentifier)
    }
}
