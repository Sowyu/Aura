import Foundation
import SwiftData

/// SwiftData model for a browsing history entry
@Model
final class History {
    @Attribute(.unique) var id: UUID // Unique identifier
    var url: URL
    var urlString: String
    var title: String
    /// Optional: a visit whose favicon has not resolved yet used to store the page URL
    /// itself here, which every reader then tried to load as an icon.
    var faviconURL: URL?
    var faviconLocalFile: URL?
    var createdAt: Date
    var visitCount: Int
    var lastAccessedAt: Date

    @Relationship(inverse: \TabContainer.history) var container: TabContainer?

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        faviconURL: URL? = nil,
        faviconLocalFile: URL? = nil,
        createdAt: Date,
        lastAccessedAt: Date,
        visitCount: Int,
        container: TabContainer? = nil
    ) {
        self.id = id
        self.url = url
        self.urlString = url.absoluteString
        self.title = title
        self.faviconURL = faviconURL
        // Both dates were overwritten with `Date()`, so an imported or backdated visit
        // silently landed at the top of the list as if it had just happened.
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.visitCount = visitCount
        self.faviconLocalFile = faviconLocalFile
        self.container = container
    }
}
