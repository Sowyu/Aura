import SwiftUI

/// The fixed, curated icon set a space can use: Zen browser's workspace glyphs, same
/// names and same order, shipped as SVGs under `aura/Resources/Icons/Spaces`.
enum SpaceIconCatalog {
    struct Symbol: Identifiable, Hashable {
        let name: String
        let keywords: String
        var id: String { name }
    }

    static let symbols: [Symbol] = [
        Symbol(name: "airplane", keywords: "travel flight plane trip"),
        Symbol(name: "american-football", keywords: "sport ball game nfl"),
        Symbol(name: "baseball", keywords: "sport ball game"),
        Symbol(name: "basket", keywords: "shop shopping store cart buy"),
        Symbol(name: "bed", keywords: "sleep rest home hotel"),
        Symbol(name: "bell", keywords: "notification alert reminder"),
        Symbol(name: "bookmark", keywords: "save read later"),
        Symbol(name: "book", keywords: "read reading library"),
        Symbol(name: "briefcase", keywords: "work job office"),
        Symbol(name: "brush", keywords: "art paint design draw"),
        Symbol(name: "bug", keywords: "debug issue insect"),
        Symbol(name: "build", keywords: "settings config preferences wrench"),
        Symbol(name: "cafe", keywords: "coffee tea break drink"),
        Symbol(name: "call", keywords: "phone contact ring"),
        Symbol(name: "card", keywords: "credit payment pay bank"),
        Symbol(name: "chat", keywords: "message talk bubble comment"),
        Symbol(name: "checkbox", keywords: "todo task done check"),
        Symbol(name: "circle", keywords: "dot shape round"),
        Symbol(name: "cloud", keywords: "weather storage sync"),
        Symbol(name: "code", keywords: "dev programming developer"),
        Symbol(name: "coins", keywords: "money cash finance currency"),
        Symbol(name: "construct", keywords: "tools repair fix hammer"),
        Symbol(name: "cutlery", keywords: "food eat restaurant dining fork knife"),
        Symbol(name: "egg", keywords: "food breakfast cook"),
        Symbol(name: "extension-puzzle", keywords: "extension plugin addon"),
        Symbol(name: "eye", keywords: "watch view visible"),
        Symbol(name: "fast-food", keywords: "burger food eat takeaway"),
        Symbol(name: "fish", keywords: "pet animal sea aquarium"),
        Symbol(name: "flag", keywords: "goal country milestone"),
        Symbol(name: "flame", keywords: "fire hot trending"),
        Symbol(name: "flask", keywords: "science lab experiment chemistry"),
        Symbol(name: "folder", keywords: "files documents directory"),
        Symbol(name: "game-controller", keywords: "game gaming play console"),
        Symbol(name: "globe-1", keywords: "idea ideas inspiration lightbulb"),
        Symbol(name: "globe", keywords: "box archive storage container"),
        Symbol(name: "grid-2x2", keywords: "grid layout dashboard apps"),
        Symbol(name: "grid-3x3", keywords: "grid dots layout apps"),
        Symbol(name: "heart", keywords: "love favorite"),
        Symbol(name: "ice-cream", keywords: "dessert sweet food treat"),
        Symbol(name: "image", keywords: "photo picture gallery camera"),
        Symbol(name: "inbox", keywords: "tray archive incoming"),
        Symbol(name: "key", keywords: "password access secret"),
        Symbol(name: "layers", keywords: "stack groups design"),
        Symbol(name: "leaf", keywords: "nature plant eco green"),
        Symbol(name: "lightning", keywords: "energy power fast bolt"),
        Symbol(name: "location", keywords: "place pin gps"),
        Symbol(name: "lock-closed", keywords: "private secure lock password"),
        Symbol(name: "logo-rss", keywords: "feed news subscribe"),
        Symbol(name: "logo-usd", keywords: "money cash dollar finance"),
        Symbol(name: "mail", keywords: "email envelope inbox"),
        Symbol(name: "map", keywords: "navigation directions atlas"),
        Symbol(name: "megaphone", keywords: "news announce marketing loud"),
        Symbol(name: "moon", keywords: "night dark sleep"),
        Symbol(name: "music", keywords: "song audio note"),
        Symbol(name: "navigate", keywords: "send arrow direction compass"),
        Symbol(name: "nuclear", keywords: "atom science energy radiation"),
        Symbol(name: "page", keywords: "document file note text"),
        Symbol(name: "palette", keywords: "art colour design paint"),
        Symbol(name: "paw", keywords: "pet animal dog cat"),
        Symbol(name: "people", keywords: "team friends group person profile"),
        Symbol(name: "pizza", keywords: "food eat italian slice"),
        Symbol(name: "planet", keywords: "space world globe universe"),
        Symbol(name: "present", keywords: "gift birthday gifts gifting"),
        Symbol(name: "rocket", keywords: "launch startup ship fast"),
        Symbol(name: "school", keywords: "study education learn university building"),
        Symbol(name: "shapes", keywords: "geometry design abstract"),
        Symbol(name: "shirt", keywords: "clothes fashion wear"),
        Symbol(name: "skull", keywords: "danger dead spooky"),
        Symbol(name: "squares", keywords: "copy duplicate stack windows"),
        Symbol(name: "square", keywords: "block shape solid"),
        Symbol(name: "star-1", keywords: "favorite rating bookmark"),
        Symbol(name: "star", keywords: "sparkle magic ai new"),
        Symbol(name: "stats-chart", keywords: "chart stats analytics data graph"),
        Symbol(name: "sun", keywords: "day light weather bright"),
        Symbol(name: "tada", keywords: "party confetti celebrate launch"),
        Symbol(name: "terminal", keywords: "shell console dev command"),
        Symbol(name: "ticket", keywords: "event tag pass cinema"),
        Symbol(name: "time", keywords: "clock schedule history later"),
        Symbol(name: "trash", keywords: "delete bin remove"),
        Symbol(name: "triangle", keywords: "shape warning play"),
        Symbol(name: "video", keywords: "movie film cinema watch record"),
        Symbol(name: "volume-high", keywords: "sound audio speaker loud"),
        Symbol(name: "wallet", keywords: "money pay budget finance"),
        Symbol(name: "warning", keywords: "alert caution danger"),
        Symbol(name: "water", keywords: "drop liquid hydrate"),
        Symbol(name: "weight", keywords: "gym workout fitness exercise sport")
    ]

    /// Spaces saved before the icon set changed still store SF Symbol names, so map the
    /// old curated set onto its nearest new glyph. Anything unmapped renders as SF Symbol.
    static let legacySymbolMap: [String: String] = [
        "airplane": "airplane",
        "banknote": "logo-usd",
        "bell": "bell",
        "bolt": "lightning",
        "book": "book",
        "bookmark": "bookmark",
        "briefcase": "briefcase",
        "bubble.left": "chat",
        "building.2": "school",
        "camera": "image",
        "cart": "basket",
        "chart.bar": "stats-chart",
        "chart.line.uptrend.xyaxis": "stats-chart",
        "chevron.left.forwardslash.chevron.right": "code",
        "cloud": "cloud",
        "creditcard": "card",
        "cup.and.saucer": "cafe",
        "drop": "water",
        "dumbbell": "weight",
        "envelope": "mail",
        "figure.run": "weight",
        "film": "video",
        "flag": "flag",
        "flame": "flame",
        "folder": "folder",
        "fork.knife": "cutlery",
        "gamecontroller": "game-controller",
        "gear": "build",
        "gift": "present",
        "globe": "planet",
        "graduationcap": "school",
        "hammer": "construct",
        "heart": "heart",
        "key": "key",
        "leaf": "leaf",
        "lightbulb": "globe-1",
        "location": "location",
        "lock": "lock-closed",
        "map": "map",
        "moon": "moon",
        "music.note": "music",
        "paintbrush": "brush",
        "pawprint": "paw",
        "person": "people",
        "person.2": "people",
        "puzzlepiece": "extension-puzzle",
        "sparkles": "star",
        "star": "star-1",
        "sun.max": "sun",
        "terminal": "terminal",
        "tray": "inbox",
        "wrench.and.screwdriver": "construct"
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
            [$0.name.replacingOccurrences(of: "-", with: " "), $0.keywords]
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
