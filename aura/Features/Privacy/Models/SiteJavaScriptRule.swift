import Foundation
import SwiftData

/// A permanent per-site JavaScript decision that overrides the global default.
/// `host` is the registrable domain, lowercased, so a rule covers every subdomain.
@Model
final class SiteJavaScriptRule {
    @Attribute(.unique) var id: UUID
    var host: String
    var isAllowed: Bool
    var createdAt: Date

    init(id: UUID = UUID(), host: String, isAllowed: Bool, createdAt: Date = Date()) {
        self.id = id
        self.host = host
        self.isAllowed = isAllowed
        self.createdAt = createdAt
    }
}
