import SwiftUI

enum LauncherSuggestionType {
    case openedTab, suggestedQuery, suggestedLink, aiChat
}

struct LauncherSuggestion: Identifiable {
    let id = UUID()
    let type: LauncherSuggestionType
    let title: String
    let name: String?
    let url: URL?
    let icon: String?
    let color: Color?
    let engineForegroundColor: Color?
    let faviconURL: URL?
    let faviconLocalFile: URL?
    /// The source's own relevance (visit count, tab recency). `nil` means "unranked",
    /// which sorts below anything ranked at the same weighted score.
    let score: Float?
    /// The query this row was matched against, used for the prefix boost. See
    /// `LauncherResultScoring.swift` for the ported scoring.
    let completingText: String?
    /// `[1...]` boost from how well `completingText` matches the row. Computed once.
    let prefixScore: Float
    let action: () -> Void

    var weightedScore: Float { (score ?? 1.0) * prefixScore }

    init(
        type: LauncherSuggestionType,
        title: String,
        name: String? = nil,
        url: URL? = nil,
        icon: String? = nil,
        color: Color? = nil,
        engineForegroundColor: Color? = nil,
        faviconURL: URL? = nil,
        faviconLocalFile: URL? = nil,
        score: Float? = nil,
        completingText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.type = type
        self.title = title
        self.name = name
        self.url = url
        self.icon = icon
        self.color = color
        self.engineForegroundColor = engineForegroundColor
        self.faviconURL = faviconURL
        self.faviconLocalFile = faviconLocalFile
        self.score = score
        self.completingText = completingText
        self.action = action
        prefixScore = LauncherScoring.prefixScore(
            query: completingText,
            text: title,
            info: url?.absoluteString,
            type: type
        )
    }

    /// Same row, re-ranked. Used when an open tab absorbs a history row's score.
    func withScore(_ newScore: Float?) -> LauncherSuggestion {
        LauncherSuggestion(
            type: type, title: title, name: name, url: url, icon: icon, color: color,
            engineForegroundColor: engineForegroundColor, faviconURL: faviconURL,
            faviconLocalFile: faviconLocalFile, score: newScore, completingText: completingText,
            action: action
        )
    }
}
