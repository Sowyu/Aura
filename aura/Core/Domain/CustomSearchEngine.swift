import AppKit
import SwiftUI

/// A search engine the user added by hand. Persisted as JSON under
/// `settings.customSearchEngines`, favicon bytes and all.
struct CustomSearchEngine: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let searchURL: String
    let aliases: [String]
    let faviconData: Data?
    let faviconBackgroundColorData: Data?
    let isAIChat: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        searchURL: String,
        aliases: [String] = [],
        faviconData: Data? = nil,
        faviconBackgroundColorData: Data? = nil,
        isAIChat: Bool = false
    ) {
        self.id = id
        self.name = name
        self.searchURL = searchURL
        self.aliases = aliases
        self.faviconData = faviconData
        self.faviconBackgroundColorData = faviconBackgroundColorData
        self.isAIChat = isAIChat
    }

    var favicon: NSImage? {
        guard let data = faviconData else { return nil }
        return NSImage(data: data)
    }

    var faviconBackgroundColor: Color? {
        guard let data = faviconBackgroundColorData else { return nil }
        do {
            let nsColor = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
            return nsColor.map(Color.init)
        } catch {
            return nil
        }
    }

    /// Builds an engine with its favicon attached, from cache when the icon is already
    /// there and over the network otherwise. The completion always lands on the main queue.
    static func createWithFavicon(
        id: String = UUID().uuidString,
        name: String,
        searchURL: String,
        aliases: [String] = [],
        isAIChat: Bool = false,
        completion: @escaping (CustomSearchEngine) -> Void
    ) {
        let base = CustomSearchEngine(
            id: id, name: name, searchURL: searchURL, aliases: aliases, isAIChat: isAIChat
        )
        let faviconService = FaviconService.shared

        if let favicon = faviconService.getFavicon(for: searchURL) {
            completion(base.attaching(favicon))
            return
        }

        faviconService.fetchFaviconSync(for: searchURL) { favicon in
            DispatchQueue.main.async { completion(base.attaching(favicon)) }
        }
    }

    /// A copy carrying `favicon`'s bytes and average colour. Nil leaves both empty.
    private func attaching(_ favicon: NSImage?) -> CustomSearchEngine {
        guard let favicon else { return self }
        let colorData = try? NSKeyedArchiver.archivedData(
            withRootObject: NSColor(Color(favicon.averageColor())),
            requiringSecureCoding: false
        )
        return CustomSearchEngine(
            id: id,
            name: name,
            searchURL: searchURL,
            aliases: aliases,
            faviconData: favicon.tiffRepresentation,
            faviconBackgroundColorData: colorData,
            isAIChat: isAIChat
        )
    }
}
