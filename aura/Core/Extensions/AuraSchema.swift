import Foundation
import SwiftData

// MARK: - V1

/// The model graph as it shipped before browsing containers.
///
/// The four classes below are copies of the shipping models cut down to their persisted
/// properties. SwiftData matches a store against a schema by its entities, so an explicit
/// migration needs the old shape as a type rather than as a comment. Nothing in the app
/// reads them: they exist so the plan has a `from` version, and so the migration can be
/// exercised against a store the old graph actually wrote.
///
/// `Download`, `SiteJavaScriptRule` and `SiteSpaceRule` did not change, so V1 points at
/// the live classes instead of copying them.
enum AuraSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            AuraSchemaV1.TabContainer.self,
            AuraSchemaV1.Tab.self,
            AuraSchemaV1.Folder.self,
            AuraSchemaV1.History.self,
            Download.self,
            SiteJavaScriptRule.self,
            SiteSpaceRule.self
        ]
    }

    @Model
    final class TabContainer {
        var id: UUID
        var name: String
        var emoji: String
        var iconSymbol: String?
        var iconColorHex: String?
        var createdAt: Date
        var lastAccessedAt: Date
        var order: Int = 0

        @Relationship(deleteRule: .cascade) var tabs: [AuraSchemaV1.Tab] = []
        @Relationship(deleteRule: .cascade) var folders: [AuraSchemaV1.Folder] = []
        @Relationship var history: [AuraSchemaV1.History] = []

        init(id: UUID = UUID(), name: String = "Default", emoji: String = "💩", order: Int = 0) {
            let now = Date()
            self.id = id
            self.name = name
            self.emoji = emoji
            self.createdAt = now
            self.lastAccessedAt = now
            self.order = order
        }
    }

    @Model
    final class Tab {
        @Attribute(.unique) var id: UUID
        var url: URL
        var urlString: String
        var savedURL: URL?
        var title: String
        var favicon: URL?
        var createdAt: Date
        var lastAccessedAt: Date?
        var type: TabType
        var order: Int
        var faviconLocalFile: URL?
        var backgroundColorHex: String = "#000000"

        @Relationship(inverse: \AuraSchemaV1.TabContainer.tabs) var container: AuraSchemaV1.TabContainer
        @Relationship var folder: AuraSchemaV1.Folder?

        init(
            id: UUID = UUID(),
            url: URL,
            title: String,
            container: AuraSchemaV1.TabContainer,
            type: TabType = .normal,
            order: Int
        ) {
            let now = Date()
            self.id = id
            self.url = url
            self.urlString = url.absoluteString
            self.title = title
            self.createdAt = now
            self.lastAccessedAt = now
            self.type = type
            self.order = order
            self.container = container
        }
    }

    @Model
    final class Folder {
        var id: UUID
        var name: String
        var order: Int = 0
        var isCollapsed: Bool = false

        @Relationship(inverse: \AuraSchemaV1.TabContainer.folders) var container: AuraSchemaV1.TabContainer
        @Relationship(deleteRule: .nullify, inverse: \AuraSchemaV1.Tab.folder) var tabs: [AuraSchemaV1.Tab] = []

        init(id: UUID = UUID(), name: String, order: Int = 0, container: AuraSchemaV1.TabContainer) {
            self.id = id
            self.name = name
            self.order = order
            self.container = container
        }
    }

    @Model
    final class History {
        @Attribute(.unique) var id: UUID
        var url: URL
        var urlString: String
        var title: String
        /// Non-optional in V1, which is the whole reason this entity is copied: a visit
        /// with no icon yet stored the page URL here.
        var faviconURL: URL
        var faviconLocalFile: URL?
        var createdAt: Date
        var visitCount: Int
        var lastAccessedAt: Date

        @Relationship(inverse: \AuraSchemaV1.TabContainer.history) var container: AuraSchemaV1.TabContainer?

        init(
            id: UUID = UUID(),
            url: URL,
            title: String,
            faviconURL: URL,
            createdAt: Date = Date(),
            lastAccessedAt: Date = Date(),
            visitCount: Int = 1,
            container: AuraSchemaV1.TabContainer? = nil
        ) {
            self.id = id
            self.url = url
            self.urlString = url.absoluteString
            self.title = title
            self.faviconURL = faviconURL
            self.createdAt = createdAt
            self.lastAccessedAt = lastAccessedAt
            self.visitCount = visitCount
            self.container = container
        }
    }
}

// MARK: - V2

/// The shipping graph: browsing containers as their own entity, a space pointing at one
/// as its default, a tab sitting in one, and `History.faviconURL` optional.
enum AuraSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            TabContainer.self, Tab.self, Folder.self, History.self,
            Download.self, SiteJavaScriptRule.self, SiteSpaceRule.self,
            BrowsingContainer.self
        ]
    }
}

// MARK: - V3

/// V2 plus bookmarks: a saved page and the one level of folder it can sit in.
///
/// Nothing V2 already had changed shape, so this schema names the same live classes and
/// adds two. `Bookmark` and `BookmarkFolder` are listed as themselves rather than copied
/// the way V1's entities are: a copy is only needed once a later version changes them.
enum AuraSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            TabContainer.self, Tab.self, Folder.self, History.self,
            Download.self, SiteJavaScriptRule.self, SiteSpaceRule.self,
            BrowsingContainer.self,
            Bookmark.self, BookmarkFolder.self
        ]
    }
}

// MARK: - V4

/// V3 plus the per-tab session: WebKit's back/forward blob, the same list in a readable
/// form, and the scroll offset a relaunch puts the page back at.
///
/// A separate entity rather than four more attributes on `Tab`, for two reasons. V2 and
/// V3 both name the *live* `Tab` class, so growing it would change the shape those two
/// schemas describe, and a store written by the shipping app would then match no version
/// in the plan at all. Freezing a copy of `Tab` into V3 would mean freezing the four
/// entities it is related to with it. The second reason is weight: a session blob is
/// around 200 bytes per back/forward entry (measured: 4.3 KB for 21), and on the tab row
/// every sidebar fetch and every maintenance pass would pull all of them into the row
/// cache alongside the four fields those passes actually read.
enum AuraSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            TabContainer.self, Tab.self, Folder.self, History.self,
            Download.self, SiteJavaScriptRule.self, SiteSpaceRule.self,
            BrowsingContainer.self,
            Bookmark.self, BookmarkFolder.self,
            TabSession.self
        ]
    }
}

// MARK: - V5

/// V4 plus the file tray: the local files the user opened, so yesterday's chapter is one
/// click away after a relaunch.
///
/// Another new entity for the reason V4 gave: every schema from V2 on names the live
/// `Tab`, `History` and `Download` classes, so nothing already in the graph may grow an
/// attribute. `OpenedFile` is listed as itself; a frozen copy is only worth making once
/// a later version changes it.
enum AuraSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            TabContainer.self, Tab.self, Folder.self, History.self,
            Download.self, SiteJavaScriptRule.self, SiteSpaceRule.self,
            BrowsingContainer.self,
            Bookmark.self, BookmarkFolder.self,
            TabSession.self,
            OpenedFile.self
        ]
    }
}

// MARK: - Plan

/// Every change so far is additive (new entities, two new to-one relationships and one
/// attribute that became optional), so every stage is lightweight. They are written
/// out anyway because an implicit lightweight migration gives no place to stand when the
/// next change is not: without a plan, a graph SwiftData refuses fails at launch with the
/// store intact and the app unusable.
enum AuraMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AuraSchemaV1.self, AuraSchemaV2.self, AuraSchemaV3.self, AuraSchemaV4.self, AuraSchemaV5.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: AuraSchemaV1.self, toVersion: AuraSchemaV2.self),
            .lightweight(fromVersion: AuraSchemaV2.self, toVersion: AuraSchemaV3.self),
            .lightweight(fromVersion: AuraSchemaV3.self, toVersion: AuraSchemaV4.self),
            .lightweight(fromVersion: AuraSchemaV4.self, toVersion: AuraSchemaV5.self)
        ]
    }
}
