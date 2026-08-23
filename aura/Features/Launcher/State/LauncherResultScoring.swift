//
//  LauncherResultScoring.swift
//  Aura
//
//  Ported from Beam (MIT licence, Copyright (c) 2022 Beam SAS):
//    Beam/Classes/Components/Autocomplete/AutocompleteResult.swift    (Sebastien Metrot)
//    Beam/Classes/Components/Autocomplete/AutocompleteManager+Sorting.swift (Remi Santos)
//    BeamCore/Extensions/String+CommonPrefix.swift                    (Sebastien Metrot)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this
//  software and associated documentation files (the "Software"), to deal in the Software
//  without restriction, including without limitation the rights to use, copy, modify,
//  merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
//  permit persons to whom the Software is furnished to do so, subject to the following
//  conditions: the above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
//  WITHOUT WARRANTY OF ANY KIND. See THIRD_PARTY_NOTICES.md.
//
//  Adapted to Aura's `LauncherSuggestion`. Beam's note, tab-group and mnemonic sources
//  have no counterpart here and are dropped; Beam also rewrites the displayed string to
//  start at the match, which Aura does not do, so `boosterScore` keeps the base intact.
//

import Foundation

extension LauncherSuggestionType {
    /// Lowest wins, as in Beam's `AutocompleteResult.Source.priority`. Only used for
    /// ordering rows of equal score and for deciding where late results may land.
    var priority: Int {
        switch self {
        case .openedTab: 0
        case .suggestedLink: 1
        // Under the rows that go somewhere, above a plain web search: a command row is
        // only ever offered when the query really looks like its name.
        case .command: 2
        case .suggestedQuery: 3
        case .aiChat: 4
        }
    }

    var isWebURLResult: Bool { self == .openedTab || self == .suggestedLink }
}

enum LauncherScoring {
    /// How much a prefix match on this kind of row is worth. URL-ish rows are boosted
    /// harder because their text is long and a match near its start is a strong signal.
    private static func weight(canMatchInside: Bool, isURLLike: Bool, hasBothTextAndInfo: Bool) -> Float {
        var booster: Float = isURLLike ? 0.1 : 0.05
        // Rows matched on their prefix only get a better score for the same match.
        if !canMatchInside { booster *= 2 }
        // Rows with no second line cannot earn an info score, so compensate.
        if !hasBothTextAndInfo, isURLLike { booster *= 1.25 }
        return booster
    }

    private struct Booster {
        var score: Float
        var boostedScore: Float
    }

    /// Prefix-only match, used where a match in the middle of the string means nothing.
    private static func simpleBooster(prefix: String, base: String?, isURLLike: Bool,
                                      hasBothTextAndInfo: Bool) -> Booster {
        guard let lowered = base?.lowercased(), !lowered.isEmpty, !prefix.isEmpty else {
            return Booster(score: 0, boostedScore: 0)
        }
        let comp = prefix.lowercased()
        let weight = weight(canMatchInside: false, isURLLike: isURLLike, hasBothTextAndInfo: hasBothTextAndInfo)
        let score = Float(lowered.commonPrefix(with: comp).count) / Float(comp.count)
        return Booster(score: score, boostedScore: weight * score)
    }

    /// Match anywhere in the string, penalised by how far in the match starts.
    private static func booster(prefix: String, base: String?, type: LauncherSuggestionType,
                                isURL: Bool, hasBothTextAndInfo: Bool) -> Booster {
        // A URL is read left to right, so only its start counts. Search rows carry the
        // query itself, so a match inside them is noise.
        let canMatchInside = !isURL && type != .suggestedQuery && type != .aiChat
        guard canMatchInside else {
            return simpleBooster(prefix: prefix, base: base, isURLLike: isURL,
                                 hasBothTextAndInfo: hasBothTextAndInfo)
        }
        guard let base, !base.isEmpty, !prefix.isEmpty else { return Booster(score: 0, boostedScore: 0) }

        let maxSubstringIndex = 10
        let skipWeight: Float = 0.1
        let range = longestCommonPrefixRange(of: prefix, in: base)
        let typeWeight = weight(canMatchInside: true, isURLLike: isURL, hasBothTextAndInfo: hasBothTextAndInfo)
        let start = min(range?.lowerBound ?? 0, maxSubstringIndex)
        let skipScore = skipWeight * Float(maxSubstringIndex - start) / Float(maxSubstringIndex)
        let score = skipScore + (1 - skipWeight) * Float(range?.count ?? 0) / Float(prefix.count)
        return Booster(score: score, boostedScore: typeWeight * score * score)
    }

    /// Combined `[1...]` boost for a row. 1 means the query told us nothing.
    static func prefixScore(query: String?, text: String, info: String?, type: LauncherSuggestionType) -> Float {
        guard let query, !query.isEmpty else { return 1 }
        let infoIsURL = type.isWebURLResult
        let infoResult = booster(prefix: query, base: info, type: type, isURL: infoIsURL,
                                 hasBothTextAndInfo: true)
        let textResult = booster(prefix: query, base: text, type: type, isURL: false,
                                 hasBothTextAndInfo: infoResult.boostedScore > 0)
        return 1 + textResult.boostedScore + infoResult.boostedScore
    }

    /// The longest prefix of `needle` found in `haystack` at the start of a word, as an
    /// offset range. Beam's `String.longestCommonPrefixRange`, unchanged in behaviour.
    static func longestCommonPrefixRange(of needle: String, in haystack: String) -> Range<Int>? {
        let starters = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        var probe = needle
        while !probe.isEmpty {
            if let idx = haystack.range(of: probe, options: .caseInsensitive)?.lowerBound {
                if idx == haystack.startIndex {
                    return 0 ..< probe.count
                }
                let previous = haystack[haystack.index(before: idx) ..< idx]
                if previous.rangeOfCharacter(from: starters) != nil {
                    let position = haystack.distance(from: haystack.startIndex, to: idx)
                    return position ..< position + probe.count
                }
            }
            probe = String(probe.dropLast())
        }
        return nil
    }

    /// `https://wikipedia.org/` and `wikipedia.org` point at the same page, so both
    /// collapse to the same dedupe key. Beam's `urlStringByRemovingUnnecessaryCharacters`.
    static func urlKey(_ url: URL?) -> String? {
        guard let url else { return nil }
        var string = url.absoluteString
        if let scheme = string.range(of: "://") { string = String(string[scheme.upperBound...]) }
        while string.hasSuffix("/") || string.hasSuffix("?") { string.removeLast() }
        return string.lowercased()
    }
}

enum LauncherResultMerger {
    /// Rows below the typed-text row. Beam uses 8 including its top row.
    static let resultsLimit = 8

    /// Higher ranked first. Beam's `AutocompleteResult.<`, reversed.
    static func ranksBefore(_ lhs: LauncherSuggestion, _ rhs: LauncherSuggestion) -> Bool {
        if lhs.weightedScore != rhs.weightedScore { return lhs.weightedScore > rhs.weightedScore }
        if (lhs.score == nil) != (rhs.score == nil) { return rhs.score == nil }
        if lhs.type.priority != rhs.type.priority { return lhs.type.priority < rhs.type.priority }
        return lhs.title < rhs.title
    }

    /// One row per address, keeping the best-ranked duplicate in the earliest slot.
    static func dedupeByURL(_ suggestions: [LauncherSuggestion]) -> [LauncherSuggestion] {
        var seen = [String: Int]()
        var result = [LauncherSuggestion]()
        for suggestion in suggestions {
            let key = LauncherScoring.urlKey(suggestion.url) ?? suggestion.title.lowercased()
            if let index = seen[key] {
                if ranksBefore(suggestion, result[index]) { result[index] = suggestion }
            } else {
                seen[key] = result.count
                result.append(suggestion)
            }
        }
        return result
    }

    /// A history row for a page that is already open becomes the open-tab row, keeping
    /// whichever score was higher. Tabs with no matching link keep their own row.
    static func mixOpenTabs(links: [LauncherSuggestion], openTabs: [LauncherSuggestion]) -> [LauncherSuggestion] {
        var unused = openTabs
        var result = [LauncherSuggestion]()
        for link in links {
            let key = LauncherScoring.urlKey(link.url)
            if key != nil, let index = unused.firstIndex(where: { LauncherScoring.urlKey($0.url) == key }) {
                let tab = unused.remove(at: index)
                result.append(tab.withScore(max(link.score ?? 0, tab.score ?? 0)))
            } else {
                result.append(link)
            }
        }
        result.append(contentsOf: unused)
        return result
    }

    /// The typed-text row always stays on top: it is what Enter does, and a row that
    /// moves under the cursor between keystrokes is how you navigate somewhere you
    /// did not mean to.
    static func merge(typed: LauncherSuggestion?, links: [LauncherSuggestion], openTabs: [LauncherSuggestion],
                      trailing: [LauncherSuggestion], limit: Int = resultsLimit) -> [LauncherSuggestion] {
        var sortable = mixOpenTabs(links: dedupeByURL(links), openTabs: openTabs)
        sortable.sort(by: ranksBefore)
        // Leave room for the search-engine rows that arrive a moment later, so they do
        // not push a row the user is already looking at off the bottom.
        let reserved = 2
        // `trailing` is outside the budget: the AI rows sit at the bottom and used to eat
        // the whole list on any query long enough to look like a question.
        let room = max(0, limit - reserved - (typed == nil ? 0 : 1))
        var results = typed.map { [$0] } ?? []
        results.append(contentsOf: sortable.prefix(room))
        results.append(contentsOf: trailing)
        return results
    }

    /// Beam's `insertSearchEngineResults`. The rows land below every better-ranked row,
    /// and never above the row the user has arrowed onto, so a late answer from the
    /// search engine cannot move the selection out from under the next Enter.
    static func insertSearchResults(_ incoming: [LauncherSuggestion], into results: [LauncherSuggestion],
                                    focused: UUID, limit: Int = resultsLimit) -> [LauncherSuggestion] {
        let existing = Set(results.map(\.title))
        let room = max(2, limit - results.count)
        let filtered = incoming.filter { !existing.contains($0.title) }.prefix(room)
        guard !filtered.isEmpty else { return results }

        let queryPriority = LauncherSuggestionType.suggestedQuery.priority
        let lastBetter = results.lastIndex { $0.type.priority < queryPriority }
        // Index 0 is the typed-text row; never insert above it.
        var index = max(1, (lastBetter ?? 0) + 1)
        if let focusedIndex = results.firstIndex(where: { $0.id == focused }), focusedIndex >= index {
            index = focusedIndex + 1
        }
        index = min(index, results.count)

        var final = results
        final.insert(contentsOf: filtered, at: index)
        return final
    }
}
