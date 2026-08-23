import Foundation
import SwiftSoup

/// Pulls the article out of a page and drops the furniture around it.
///
/// The scoring is the readability heuristic in miniature: every paragraph of real length
/// credits its parent and, at half weight, its grandparent, so the winner is the tightest
/// element that still holds the whole body rather than the outermost wrapper that
/// happens to contain it. The score is then scaled down by link density, which is what
/// separates an article from a navigation column made of the same number of words.
///
/// Everything here is pure: markup in, value type out, no WebKit and no main actor, so
/// the caller can run it off the main thread and the tests can run it against a string.
enum ReaderExtractor {
    /// Never article text, whatever they score.
    private static let strippedSelector =
        "script, style, noscript, nav, aside, footer, form, iframe, svg, canvas, template, "
            + "[role=navigation], [role=banner], [role=complementary], [aria-hidden=true]"

    /// Elements that can own a body of text.
    private static let candidateSelector = "article, main, section, div, td"

    /// A paragraph shorter than this is a caption, a byline or a button label.
    private static let minimumParagraphLength = 25

    /// Images this small are tracking pixels and spacer gifs.
    private static let minimumImageEdge = 32

    static func article(fromHTML html: String, baseURL: URL?) -> ReaderArticle? {
        guard let document = try? SwiftSoup.parse(html, baseURL?.absoluteString ?? "") else {
            return nil
        }
        let title = (try? metaTitle(document)) ?? ""
        let byline = try? metaContent(document, selectors: [
            "meta[property=article:author]", "meta[name=author]", "[rel=author]"
        ])
        let siteName = try? metaContent(document, selectors: ["meta[property=og:site_name]"])

        // Removal happens after the metadata is read: `og:` tags live in the head next to
        // the scripts that go first.
        _ = try? document.select(strippedSelector).remove()

        guard let body = document.body() else { return nil }
        let root = (try? bestCandidate(in: document)) ?? body
        var blocks: [ReaderBlock] = []
        collect(root, into: &blocks)
        blocks = tidy(blocks, title: title)
        guard !blocks.isEmpty else { return nil }
        return ReaderArticle(
            title: title.isEmpty ? (baseURL?.host ?? "Untitled") : title,
            byline: byline?.isEmpty == false ? byline : nil,
            siteName: siteName?.isEmpty == false ? siteName : nil,
            blocks: blocks
        )
    }

    // MARK: - Metadata

    private static func metaTitle(_ document: Document) throws -> String {
        if let og = try? metaContent(document, selectors: ["meta[property=og:title]"]), !og.isEmpty {
            return og
        }
        let title = try document.title().trimmed()
        if !title.isEmpty { return title }
        guard let heading = try document.select("h1").first() else { return "" }
        return try heading.text().trimmed()
    }

    private static func metaContent(_ document: Document, selectors: [String]) throws -> String {
        for selector in selectors {
            guard let element = try document.select(selector).first() else { continue }
            let content = try element.attr("content")
            if !content.isEmpty { return content.trimmed() }
            let text = try element.text()
            if !text.isEmpty { return text.trimmed() }
        }
        return ""
    }

    // MARK: - Scoring

    /// Keys are `ObjectIdentifier`, not the elements themselves: SwiftSoup hashes a node
    /// by serialising its whole subtree, so using elements as dictionary keys turns the
    /// tally below into a quadratic walk of the document.
    private static func bestCandidate(in document: Document) throws -> Element? {
        var scores: [ObjectIdentifier: Double] = [:]
        var elements: [ObjectIdentifier: Element] = [:]

        func credit(_ element: Element, _ score: Double) {
            let key = ObjectIdentifier(element)
            scores[key, default: 0] += score
            elements[key] = element
        }

        for paragraph in try document.select("p, pre, blockquote") {
            let text = (try? paragraph.text()) ?? ""
            guard text.count >= minimumParagraphLength else { continue }
            // Length in hundreds, capped, plus one point for the paragraph itself and one
            // per comma: sentences with clauses are prose, lists of links are not.
            let commas = text.filter { $0 == "," }.count
            let score = 1 + Double(min(text.count / 100, 3)) + Double(min(commas, 3))
            guard let parent = paragraph.parent() else { continue }
            credit(parent, score)
            if let grandparent = parent.parent() {
                credit(grandparent, score / 2)
            }
        }
        guard !scores.isEmpty else { return nil }

        var best: Element?
        var bestScore = 0.0
        for (key, score) in scores {
            guard let element = elements[key],
                  (try? element.iS(candidateSelector)) == true
            else { continue }
            let adjusted = score * (1 - linkDensity(of: element))
            guard adjusted > bestScore else { continue }
            bestScore = adjusted
            best = element
        }
        return best
    }

    /// Share of the element's text that sits inside links. A menu is close to 1, an
    /// article with a few references is close to 0.
    private static func linkDensity(of element: Element) -> Double {
        let total = ((try? element.text()) ?? "").count
        guard total > 0 else { return 1 }
        let linked = ((try? element.select("a")) ?? Elements())
            .reduce(0) { $0 + (((try? $1.text()) ?? "").count) }
        return min(Double(linked) / Double(total), 1)
    }

    // MARK: - Walking

    private static let blockTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre",
        "figure", "img", "div", "section", "article", "table", "main", "picture"
    ]

    private static func collect(_ element: Element, into blocks: inout [ReaderBlock]) {
        switch element.tagNameNormal() {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(element.tagNameNormal().dropFirst()) ?? 2
            append(.heading(level: level, text: text(of: element)), to: &blocks)
        case "p":
            append(.paragraph(text(of: element)), to: &blocks)
            // A figure-less inline image would otherwise be dropped with its paragraph.
            for image in images(in: element) { blocks.append(image) }
        case "blockquote":
            append(.quote(text(of: element)), to: &blocks)
        case "pre":
            append(.code(rawText(of: element)), to: &blocks)
        case "ul", "ol":
            let items = element.children()
                .filter { $0.tagNameNormal() == "li" }
                .map { text(of: $0) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { return }
            blocks.append(.list(ordered: element.tagNameNormal() == "ol", items: items))
        case "img":
            if let image = image(from: element) { blocks.append(image) }
        case "br", "hr", "figcaption":
            return
        default:
            let children = element.children()
            let hasBlockChild = children.contains { blockTags.contains($0.tagNameNormal()) }
            if !hasBlockChild {
                // A bare `<div>text</div>` is prose too, and the tags that wrap it
                // (span, em, a) never reach this branch on their own.
                append(.paragraph(text(of: element)), to: &blocks)
                for image in images(in: element) { blocks.append(image) }
                return
            }
            for child in children { collect(child, into: &blocks) }
        }
    }

    private static func append(_ block: ReaderBlock, to blocks: inout [ReaderBlock]) {
        guard block.textLength > 0 else { return }
        blocks.append(block)
    }

    private static func text(of element: Element) -> String {
        ((try? element.text()) ?? "").trimmed()
    }

    /// `pre` keeps its line breaks; `text()` collapses them into single spaces.
    private static func rawText(of element: Element) -> String {
        let raw = (try? element.text(trimAndNormaliseWhitespace: false)) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func images(in element: Element) -> [ReaderBlock] {
        ((try? element.select("img")) ?? Elements()).compactMap { image(from: $0) }
    }

    /// Only absolute http(s) sources survive: a relative path with no base URL to resolve
    /// against would render as a broken box, and a `data:` sprite is never article art.
    private static func image(from element: Element) -> ReaderBlock? {
        let raw = ["abs:src", "abs:data-src", "abs:data-original", "abs:data-lazy-src"]
            .lazy
            .compactMap { try? element.attr($0) }
            .first { !$0.isEmpty }
        guard let raw,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        for attribute in ["width", "height"] {
            guard let value = try? element.attr(attribute), let number = Int(value) else { continue }
            if number < minimumImageEdge { return nil }
        }
        let alt = (try? element.attr("alt"))?.trimmed()
        return .image(url: url, alt: alt?.isEmpty == false ? alt : nil)
    }

    // MARK: - Tidying

    /// Drops the heading that only repeats the title the view already draws, and the
    /// duplicate images a lazy-loading gallery leaves behind.
    private static func tidy(_ blocks: [ReaderBlock], title: String) -> [ReaderBlock] {
        var result: [ReaderBlock] = []
        var seenImages: Set<String> = []
        for block in blocks {
            switch block {
            case let .heading(_, text) where result.isEmpty && !title.isEmpty && text == title:
                continue
            case let .image(url, _):
                guard seenImages.insert(url.absoluteString).inserted else { continue }
                result.append(block)
            default:
                result.append(block)
            }
        }
        return result
    }
}

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
