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

    /// Creates a ModelContainer using the standard Aura database configuration
    static func createOraContainer(isPrivate: Bool = false) throws -> ModelContainer {
        return try ModelContainer(
            for: TabContainer.self, History.self, Download.self, SiteJavaScriptRule.self, SiteSpaceRule.self,
            configurations: oraDatabase(isPrivate: isPrivate)
        )
    }
}
