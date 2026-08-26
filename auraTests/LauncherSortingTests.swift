import Foundation
@testable import Aura
import Testing

/// Covers the scoring and merge ported from Beam (see `LauncherResultScoring.swift`),
/// plus the two omnibox rules Aura layers on top: the typed text owns row 0, and a late
/// answer from the search engine never moves the row the user has arrowed onto.
@Suite("Launcher sorting")
@MainActor
struct LauncherSortingTests {
    private func link(
        _ title: String,
        url: String,
        completing: String? = nil,
        score: Float? = nil
    ) -> LauncherSuggestion {
        LauncherSuggestion(
            type: .suggestedLink,
            title: title,
            url: URL(string: url),
            score: score,
            completingText: completing,
            action: {}
        )
    }

    private func tab(
        _ title: String,
        url: String,
        completing: String? = nil,
        score: Float? = nil
    ) -> LauncherSuggestion {
        LauncherSuggestion(
            type: .openedTab,
            title: title,
            url: URL(string: url),
            score: score,
            completingText: completing,
            action: {}
        )
    }

    private func query(_ title: String, completing: String? = nil) -> LauncherSuggestion {
        LauncherSuggestion(type: .suggestedQuery, title: title, completingText: completing, action: {})
    }

    @Test("A title that starts with the query outranks one that only contains it")
    func prefixBoost() {
        let matching = link("Red Panda", url: "https://a.com", completing: "red", score: 1)
        let other = link("A Panda That Is Red", url: "https://b.com", completing: "red", score: 1)

        #expect(matching.prefixScore > other.prefixScore)
        #expect(LauncherResultMerger.ranksBefore(matching, other))
    }

    @Test("No query means no boost")
    func noQueryNoBoost() {
        #expect(link("Red Panda", url: "https://a.com").prefixScore == 1)
    }

    @Test("The same address appears once, keeping the better row")
    func dedupesByURL() {
        let rows = [
            link("Wikipedia", url: "https://wikipedia.org/", completing: "wiki", score: 1),
            link("Wikipedia", url: "wikipedia.org", completing: "wiki", score: 2),
            link("Example", url: "https://example.com", completing: "wiki", score: 1)
        ]

        let deduped = LauncherResultMerger.dedupeByURL(rows)

        #expect(deduped.count == 2)
        #expect(deduped[0].score == 2)
    }

    @Test("An open tab replaces the history row for the same page and keeps the best score")
    func openTabAbsorbsHistoryRow() {
        let links = [link("News", url: "https://news.com", completing: "news", score: 2)]
        let tabs = [tab("News", url: "https://news.com/", completing: "news", score: 1)]

        let mixed = LauncherResultMerger.mixOpenTabs(links: links, openTabs: tabs)

        #expect(mixed.count == 1)
        #expect(mixed[0].type == .openedTab)
        #expect(mixed[0].score == 2)
    }

    @Test("An open tab with no matching history row keeps its own row")
    func unmatchedTabSurvives() {
        let mixed = LauncherResultMerger.mixOpenTabs(
            links: [link("News", url: "https://news.com", completing: "n", score: 1)],
            openTabs: [tab("Mail", url: "https://mail.com", completing: "n", score: 1)]
        )

        #expect(mixed.count == 2)
        #expect(mixed[1].title == "Mail")
    }

    @Test("The typed text stays on row 0 even when a tab for it is open")
    func typedTextOwnsTheTopRow() {
        let typed = link("news.com", url: "https://news.com", completing: "news.com", score: nil)
        let merged = LauncherResultMerger.merge(
            typed: typed,
            links: [],
            openTabs: [tab("News", url: "https://news.com", completing: "news.com", score: 9)],
            trailing: []
        )

        #expect(merged[0].id == typed.id)
        #expect(merged[1].type == .openedTab)
    }

    @Test("Trailing rows stay at the bottom and never crowd out the links")
    func mergeKeepsTrailingLast() {
        let links = (0 ..< 8).map { link("Site \($0)", url: "https://s\($0).com", completing: "s", score: 1) }
        let merged = LauncherResultMerger.merge(
            typed: query("s - Google"),
            links: links,
            openTabs: [],
            trailing: (0 ..< 4).map { query("ask AI \($0)") },
            limit: 8
        )

        #expect(merged.last?.title == "ask AI 3")
        // Row 0 plus two slots held for the search engine leave five link rows.
        #expect(merged.filter { $0.type == .suggestedLink }.count == 5)
    }

    @Test("Late search results land below the links, never on row 0")
    func lateResultsGoBelowLinks() {
        let results = [
            query("news - Google"),
            link("News", url: "https://news.com", completing: "news", score: 1)
        ]

        let final = LauncherResultMerger.insertSearchResults(
            [query("news today"), query("news uk")],
            into: results,
            focused: results[0].id
        )

        #expect(final[0].id == results[0].id)
        #expect(final[1].id == results[1].id)
        #expect(final[2].title == "news today")
    }

    @Test("Late search results never displace the row the user arrowed onto")
    func lateResultsKeepTheFocusedRow() {
        let results = [
            query("news - Google"),
            link("News", url: "https://news.com", completing: "news", score: 1),
            query("ask AI")
        ]
        let focused = results[2]

        let final = LauncherResultMerger.insertSearchResults(
            [query("news today")], into: results, focused: focused.id
        )

        #expect(final.firstIndex { $0.id == focused.id } == 2)
        #expect(final[3].title == "news today")
    }

    @Test("A result already on the list is not inserted twice")
    func lateResultsDedupe() {
        let results = [query("news - Google"), query("news today")]

        let final = LauncherResultMerger.insertSearchResults(
            [query("news today")], into: results, focused: results[0].id
        )

        #expect(final.count == 2)
    }

    @Test("Arrow keys recover when focus points at a row that is gone")
    func arrowKeysRecoverFromStaleFocus() {
        let model = LauncherViewModel()
        model.suggestions = [query("a"), query("b")]
        model.focusedElement = UUID()

        model.moveFocusedElement(.down)
        #expect(model.focusedElement == model.suggestions[0].id)

        model.moveFocusedElement(.down)
        #expect(model.focusedElement == model.suggestions[1].id)

        model.moveFocusedElement(.down)
        #expect(model.focusedElement == model.suggestions[0].id)
    }

    @Test("Arrow keys on an empty list do nothing")
    func arrowKeysOnEmptyList() {
        let model = LauncherViewModel()
        let focus = model.focusedElement

        model.moveFocusedElement(.up)

        #expect(model.focusedElement == focus)
    }

    @Test("Addresses that differ only in scheme or trailing slash share a key")
    func urlKeyNormalisation() {
        #expect(LauncherScoring.urlKey(URL(string: "https://a.com/")) == "a.com")
        #expect(LauncherScoring.urlKey(URL(string: "http://A.com")) == "a.com")
        #expect(LauncherScoring.urlKey(URL(string: "https://a.com/x")) == "a.com/x")
        #expect(LauncherScoring.urlKey(nil) == nil)
    }

    @Test("The common-prefix range only matches at a word start")
    func commonPrefixRange() {
        #expect(LauncherScoring.longestCommonPrefixRange(of: "red", in: "red panda") == 0 ..< 3)
        #expect(LauncherScoring.longestCommonPrefixRange(of: "panda", in: "red panda") == 4 ..< 9)
        #expect(LauncherScoring.longestCommonPrefixRange(of: "anda", in: "red panda") == nil)
    }

    /// The local half of a keystroke (a bounded history fetch plus a scan of every open
    /// tab) used to run on the main thread for every character typed.
    @Test("The first keystroke after a pause searches now, a burst waits out the window")
    func localSearchDebouncePolicy() {
        let now = Date()

        // Nothing has run yet, so the first character gets its list straight away.
        #expect(LauncherViewModel.runsLocalSearchNow(lastRunAt: nil, now: now))
        // Typing fast: the run is deferred and the pending one replaced.
        #expect(!LauncherViewModel.runsLocalSearchNow(lastRunAt: now.addingTimeInterval(-0.01), now: now))
        #expect(!LauncherViewModel.runsLocalSearchNow(lastRunAt: now.addingTimeInterval(-0.039), now: now))
        // A pause longer than the window counts as idle again.
        #expect(LauncherViewModel.runsLocalSearchNow(lastRunAt: now.addingTimeInterval(-0.05), now: now))
        #expect(LauncherViewModel.runsLocalSearchNow(lastRunAt: now.addingTimeInterval(-5), now: now))

        #expect(LauncherViewModel.localSearchDebounce == 0.04)
    }

    /// The launcher and the address bar hand the same string to `createSearchURL`.
    /// `.urlQueryAllowed` passes &, + and # straight through, which used to split one
    /// search into several query parameters and drop everything after the "#".
    @Test("A search query keeps &, + and # inside one query parameter")
    func searchQueryEncodingSurvivesPunctuation() throws {
        let service = SearchEngineService()
        let engine = try #require(service.getSearchEngine(byName: "Google"))
        let raw = "c++ tutorials & more #1"

        let url = try #require(service.createSearchURL(for: engine, query: raw))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        // Nothing leaked into a fragment, and the query is still one "q" parameter.
        #expect(components.fragment == nil)
        let item = try #require(components.queryItems?.first { $0.name == "q" })
        #expect(item.value == raw)

        let encoded = try #require(components.percentEncodedQuery?
            .components(separatedBy: "q=").last)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("&"))
        #expect(!encoded.contains("#"))

        // Same rule for the suggestions endpoint.
        let suggestions = try #require(service.createSuggestionsURL(
            urlString: "https://example.com/complete?q={query}", query: raw
        ))
        let suggestionQuery = try #require(
            URLComponents(url: suggestions, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "q" }
        )
        #expect(suggestionQuery.value == raw)
    }
}
