import Foundation
import SwiftData

/// A permanent "this site belongs to that space" decision. `host` is the registrable
/// domain, lowercased, so a rule covers every subdomain.
@Model
final class SiteSpaceRule {
    @Attribute(.unique) var id: UUID
    var host: String
    var containerID: UUID
    var createdAt: Date

    init(id: UUID = UUID(), host: String, containerID: UUID, createdAt: Date = Date()) {
        self.id = id
        self.host = host
        self.containerID = containerID
        self.createdAt = createdAt
    }
}
