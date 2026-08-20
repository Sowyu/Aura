import SwiftUI

/// The fixed, curated icon set a space can use, mirroring Zen browser's workspace icons
/// mapped onto SF Symbols with the same meaning.
enum SpaceIconCatalog {
    struct Symbol: Identifiable, Hashable {
        let name: String
        let keywords: String
        var id: String { name }
    }

    static let symbols: [Symbol] = [
        Symbol(name: "house", keywords: "home main"),
        Symbol(name: "briefcase", keywords: "work job office"),
        Symbol(name: "person", keywords: "profile me personal"),
        Symbol(name: "person.2", keywords: "people team friends group"),
        Symbol(name: "gamecontroller", keywords: "game gaming play"),
        Symbol(name: "book", keywords: "read reading library"),
        Symbol(name: "graduationcap", keywords: "school study education learn"),
        Symbol(name: "music.note", keywords: "music song audio"),
        Symbol(name: "film", keywords: "movie video cinema watch"),
        Symbol(name: "camera", keywords: "photo picture"),
        Symbol(name: "paintbrush", keywords: "art paint design draw"),
        Symbol(name: "hammer", keywords: "build tools diy"),
        Symbol(name: "wrench.and.screwdriver", keywords: "tools repair fix"),
        Symbol(name: "terminal", keywords: "shell console dev"),
        Symbol(name: "chevron.left.forwardslash.chevron.right", keywords: "code dev programming"),
        Symbol(name: "globe", keywords: "web internet browse world"),
        Symbol(name: "airplane", keywords: "travel flight plane"),
        Symbol(name: "car", keywords: "drive auto vehicle"),
        Symbol(name: "cart", keywords: "shop shopping store"),
        Symbol(name: "creditcard", keywords: "card payment pay"),
        Symbol(name: "banknote", keywords: "money cash finance"),
        Symbol(name: "chart.bar", keywords: "chart stats analytics data"),
        Symbol(name: "chart.line.uptrend.xyaxis", keywords: "growth trend stocks invest"),
        Symbol(name: "heart", keywords: "love favorite"),
        Symbol(name: "star", keywords: "favorite rating"),
        Symbol(name: "bolt", keywords: "energy power fast"),
        Symbol(name: "flame", keywords: "fire hot trending"),
        Symbol(name: "leaf", keywords: "nature plant eco green"),
        Symbol(name: "drop", keywords: "water liquid"),
        Symbol(name: "moon", keywords: "night dark sleep"),
        Symbol(name: "sun.max", keywords: "sun day light weather"),
        Symbol(name: "cloud", keywords: "weather storage"),
        Symbol(name: "sparkles", keywords: "ai magic new"),
        Symbol(name: "lightbulb", keywords: "idea ideas inspiration"),
        Symbol(name: "flag", keywords: "goal country"),
        Symbol(name: "bookmark", keywords: "save read later"),
        Symbol(name: "tag", keywords: "label category"),
        Symbol(name: "folder", keywords: "files documents"),
        Symbol(name: "tray", keywords: "inbox archive"),
        Symbol(name: "envelope", keywords: "mail email inbox"),
        Symbol(name: "bubble.left", keywords: "chat message talk"),
        Symbol(name: "phone", keywords: "call contact"),
        Symbol(name: "bell", keywords: "notification alert"),
        Symbol(name: "lock", keywords: "private secure"),
        Symbol(name: "shield", keywords: "security protect"),
        Symbol(name: "key", keywords: "password access"),
        Symbol(name: "gear", keywords: "settings config preferences"),
        Symbol(name: "puzzlepiece", keywords: "extension plugin"),
        Symbol(name: "gift", keywords: "present birthday"),
        Symbol(name: "cup.and.saucer", keywords: "coffee tea break drink"),
        Symbol(name: "fork.knife", keywords: "food eat restaurant dining"),
        Symbol(name: "pawprint", keywords: "pet animal dog cat"),
        Symbol(name: "figure.run", keywords: "run fitness exercise sport"),
        Symbol(name: "dumbbell", keywords: "gym workout fitness weights"),
        Symbol(name: "medical.thermometer", keywords: "health temperature medical"),
        Symbol(name: "pills", keywords: "medicine health pharmacy"),
        Symbol(name: "cross.case", keywords: "health medical first aid doctor"),
        Symbol(name: "building.2", keywords: "office company business city"),
        Symbol(name: "map", keywords: "navigation directions"),
        Symbol(name: "location", keywords: "place pin gps")
    ]

    /// Swatch row shown under the search field. `nil` is the "Auto" swatch (theme foreground).
    static let palette: [String] = [
        "#FF6B6B", "#FFA94D", "#FFD43B", "#69DB7C", "#38D9A9",
        "#4DABF7", "#748FFC", "#DA77F2", "#F783AC", "#ADB5BD"
    ]

    static func color(hex: String?) -> Color? {
        guard let hex, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    static func search(_ query: String) -> [Symbol] {
        SpaceIconSearch.rank(query: query, in: symbols) {
            [$0.name.replacingOccurrences(of: ".", with: " "), $0.keywords]
        }
    }
}

/// Shared ranking for both picker tabs: prefix matches first, then substring matches,
/// original order preserved inside each bucket.
enum SpaceIconSearch {
    /// `0` for a word-prefix hit, `1` for a substring hit, `nil` when nothing matches.
    static func score(query: String, fields: [String]) -> Int? {
        var best: Int?
        for field in fields {
            if field.hasPrefix(query) { return 0 }
            for word in field.split(separator: " ") where word.hasPrefix(query) { return 0 }
            if field.contains(query) { best = 1 }
        }
        return best
    }

    private struct Hit<T> {
        let score: Int
        let index: Int
        let item: T
    }

    static func rank<T>(query: String, in items: [T], fields: (T) -> [String]) -> [T] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.enumerated()
            .compactMap { index, item -> Hit<T>? in
                guard let score = score(query: query, fields: fields(item).map { $0.lowercased() }) else { return nil }
                return Hit(score: score, index: index, item: item)
            }
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score < $1.score }
            .map(\.item)
    }
}
