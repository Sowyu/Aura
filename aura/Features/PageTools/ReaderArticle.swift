import Foundation

/// One piece of an extracted article, in document order.
enum ReaderBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote(String)
    case code(String)
    case list(ordered: Bool, items: [String])
    case image(url: URL, alt: String?)

    /// Characters of prose. Images count for nothing, which is what keeps a gallery from
    /// passing for an article.
    var textLength: Int {
        switch self {
        case let .heading(_, text), let .paragraph(text), let .quote(text), let .code(text):
            return text.count
        case let .list(_, items):
            return items.reduce(0) { $0 + $1.count }
        case .image:
            return 0
        }
    }
}

/// The result of running a page through `ReaderExtractor`.
struct ReaderArticle: Equatable, Sendable {
    var title: String
    var byline: String?
    var siteName: String?
    var blocks: [ReaderBlock]

    var textLength: Int {
        blocks.reduce(0) { $0 + $1.textLength }
    }

    /// Below this a page is a menu, a search result list or a paywall stub, and showing
    /// it as an article is worse than saying nothing was found.
    static let minimumTextLength = 200

    var isReadable: Bool {
        textLength >= Self.minimumTextLength
    }
}
