import Foundation
@testable import Aura
import Testing

@Suite("Reader extraction")
struct ReaderExtractorTests {
    private let base = URL(string: "https://example.test/guide/index.html")

    // MARK: - Fixtures

    /// A news page: real article inside a wrapper, with furniture around it.
    private let newsPage = """
    <html><head>
      <title>Example Times | The Real Headline</title>
      <meta property="og:title" content="The Real Headline">
      <meta name="author" content="Jane Roe">
      <meta property="og:site_name" content="Example Times">
    </head><body>
      <nav><a href="/a">Home</a><a href="/b">World and business news today</a></nav>
      <div id="wrap">
        <article>
          <h1>The Real Headline</h1>
          <p>First paragraph of the story, long enough to be counted, with a comma in it.</p>
          <p>Second paragraph of the story, also long enough to count, carrying it along.</p>
          <p>Third paragraph of the story, still long enough, and it lands the point here.</p>
        </article>
      </div>
      <aside><p>Sponsored: buy this thing now, it is a very good thing to buy today.</p></aside>
      <footer><p>Copyright notice, long enough on its own to be counted as a paragraph.</p></footer>
      <script>var tracker = 1;</script>
    </body></html>
    """

    /// A page whose link column carries more raw text than its article.
    private let linkHeavyPage = """
    <html><head><title>Portal</title></head><body>
      <div id="links">
        <p><a href="/1">A long link title that runs on for quite a while indeed here</a>
           <a href="/2">Another long link title that also runs on for a while</a>
           <a href="/3">And a third long link title, padding out the column further</a></p>
        <p><a href="/4">More link text, long enough on its own to be scored as prose</a>
           <a href="/5">Yet more link text, again long enough to be scored as prose</a></p>
      </div>
      <div id="story">
        <p>Real prose here, long enough to count, with commas, clauses, and a point.</p>
        <p>More real prose, also long enough to count, carrying the argument to its end.</p>
      </div>
    </body></html>
    """

    /// Every block kind the reader renders, plus a tracking pixel and a relative image.
    private let mixedPage = """
    <html><head><title>Guide</title></head><body>
      <div class="content">
        <h2>Getting started with the thing</h2>
        <p>An introduction paragraph that is definitely long enough to be scored here.</p>
        <ul><li>First item</li><li>Second item</li></ul>
        <blockquote>A quotation that carries some weight and is long enough to matter.</blockquote>
        <pre>let x = 1
    let y = 2</pre>
        <p>A closing paragraph that is also long enough to be scored, with a comma in it.</p>
        <img src="/images/photo.png" alt="A photo" width="640" height="480">
        <img src="/pixel.gif" width="1" height="1">
      </div>
    </body></html>
    """

    // MARK: - Tests

    @Test("the article wins and the furniture around it is dropped")
    func newsExtraction() throws {
        let article = try #require(ReaderExtractor.article(fromHTML: newsPage, baseURL: base))
        #expect(article.title == "The Real Headline")
        #expect(article.byline == "Jane Roe")
        #expect(article.siteName == "Example Times")
        #expect(article.isReadable)

        let prose = article.blocks.compactMap { block -> String? in
            if case let .paragraph(text) = block { return text }
            return nil
        }
        #expect(prose.count == 3)
        #expect(prose[0].hasPrefix("First paragraph"))

        let everything = prose.joined(separator: " ")
        #expect(!everything.contains("Sponsored"))
        #expect(!everything.contains("Copyright"))
        #expect(!everything.contains("World and business"))
        #expect(!everything.contains("tracker"))
    }

    @Test("the heading that only repeats the title is dropped")
    func duplicateHeadingRemoved() throws {
        let article = try #require(ReaderExtractor.article(fromHTML: newsPage, baseURL: base))
        if case let .heading(_, text) = article.blocks[0] {
            #expect(text != article.title)
        }
    }

    @Test("link density beats raw length")
    func linkColumnLoses() throws {
        let article = try #require(ReaderExtractor.article(fromHTML: linkHeavyPage, baseURL: base))
        let prose = article.blocks.compactMap { block -> String? in
            if case let .paragraph(text) = block { return text }
            return nil
        }
        #expect(prose.count == 2)
        #expect(prose.allSatisfy { $0.contains("prose") })
    }

    @Test("headings, lists, quotes, code and images all survive in order")
    func blockKinds() throws {
        let article = try #require(ReaderExtractor.article(fromHTML: mixedPage, baseURL: base))
        #expect(article.title == "Guide")

        guard article.blocks.count == 7 else {
            Issue.record("expected 7 blocks, got \(article.blocks.count): \(article.blocks)")
            return
        }
        #expect(article.blocks[0] == .heading(level: 2, text: "Getting started with the thing"))
        if case let .paragraph(text) = article.blocks[1] {
            #expect(text.hasPrefix("An introduction"))
        } else {
            Issue.record("block 1 is not a paragraph: \(article.blocks[1])")
        }
        #expect(article.blocks[2] == .list(ordered: false, items: ["First item", "Second item"]))
        if case let .quote(text) = article.blocks[3] {
            #expect(text.hasPrefix("A quotation"))
        } else {
            Issue.record("block 3 is not a quote: \(article.blocks[3])")
        }
        if case let .code(text) = article.blocks[4] {
            #expect(text.contains("let x = 1"))
            #expect(text.contains("let y = 2"))
        } else {
            Issue.record("block 4 is not code: \(article.blocks[4])")
        }
        let photo = try #require(URL(string: "https://example.test/images/photo.png"))
        #expect(article.blocks[6] == .image(url: photo, alt: "A photo"))
    }

    @Test("a page with no prose reports nothing to read")
    func emptyPage() {
        let markup = "<html><head><title>Nothing</title></head><body><div></div></body></html>"
        let article = ReaderExtractor.article(fromHTML: markup, baseURL: base)
        #expect(article?.isReadable != true)
    }
}
