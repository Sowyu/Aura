import Foundation
import SwiftData

extension ModelConfiguration {
    /// Shared model configuration for the main Aura database
    static func oraDatabase(isPrivate: Bool = false) -> ModelConfiguration {
        if isPrivate {
            return ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            return ModelConfiguration(
                "OraData",
                schema: Schema([
                    TabContainer.self, History.self, Download.self,
                    SiteJavaScriptRule.self, SiteSpaceRule.self
                ]),
                url: URL.applicationSupportDirectory.appending(path: "Aura/OraData.sqlite")
            )
        }
    }

    /// Returns the ModelContainer for the standard Aura database.
    ///
    /// The persistent one is built once and shared. Every window used to open its own
    /// container over the same SQLite file, so each held a separate row cache and neither
    /// saw the other's writes until a refetch.
    ///
    /// A private window still gets a fresh in-memory container: sharing one would leak
    /// tabs between private windows, which is the opposite of what they are for.
    static func createOraContainer(isPrivate: Bool = false) throws -> ModelContainer {
        if isPrivate {
            return try ModelContainer(
                for: TabContainer.self, History.self, Download.self, SiteJavaScriptRule.self, SiteSpaceRule.self,
                configurations: oraDatabase(isPrivate: true)
            )
        }
        return try sharedContainerLock.withLock {
            if let sharedContainer { return sharedContainer }
            let container = try ModelContainer(
                for: TabContainer.self, History.self, Download.self, SiteJavaScriptRule.self, SiteSpaceRule.self,
                configurations: oraDatabase(isPrivate: false)
            )
            sharedContainer = container
            return container
        }
    }

    /// `createOraContainer` is called off the main actor by the rule services, so the
    /// cache needs its own lock.
    private nonisolated(unsafe) static var sharedContainer: ModelContainer?
    private static let sharedContainerLock = NSLock()
}
