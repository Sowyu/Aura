import AppKit
import Foundation
@testable import Aura
import Testing

@Suite("Space icon picker")
struct SpaceIconTests {
    private func item(_ emoji: String, _ name: String, _ code: [String]) -> EmojiItem {
        EmojiItem(emoji: emoji, name: name, code: code)
    }

    @Test func skinToneFormsCollapseIntoTheirBase() {
        let grouped = EmojiVariants.group([
            item("👋", "waving hand", ["1F44B"]),
            item("👋🏻", "waving hand: light skin tone", ["1F44B", "1F3FB"]),
            item("👋🏿", "waving hand: dark skin tone", ["1F44B", "1F3FF"]),
            item("🍕", "pizza", ["1F355"])
        ])

        #expect(grouped.map(\.emoji) == ["👋", "🍕"])
        #expect(grouped[0].variants.map(\.emoji) == ["👋🏻", "👋🏿"])
        #expect(grouped[1].variants.isEmpty)
    }

    @Test func hairAndVariationSelectorFormsCollapseToo() {
        let grouped = EmojiVariants.group([
            item("🧑", "person", ["1F9D1"]),
            item("🧑‍🦰", "person: red hair", ["1F9D1", "200D", "1F9B0"]),
            item("🧑🏽‍🦱", "person: medium skin tone, curly hair", ["1F9D1", "1F3FD", "200D", "1F9B1"]),
            item("🕵️‍♂️", "man detective", ["1F575", "FE0F", "200D", "2642", "FE0F"]),
            item("🕵🏻‍♂️", "man detective: light skin tone", ["1F575", "1F3FB", "200D", "2642", "FE0F"])
        ])

        #expect(grouped.count == 2)
        #expect(grouped[0].emoji == "🧑")
        #expect(grouped[0].variants.count == 2)
        #expect(grouped[1].emoji == "🕵️‍♂️")
        #expect(grouped[1].variants.count == 1)
    }

    @Test func searchPrefersPrefixMatchesOverSubstrings() {
        let ranked = SpaceIconSearch.rank(query: "car", in: ["postcard", "car", "cart"]) { [$0] }
        #expect(ranked == ["car", "cart", "postcard"])
    }

    @Test func searchMatchesKeywordsAndDashedNames() {
        #expect(SpaceIconCatalog.search("rocket").first?.name == "rocket")
        #expect(SpaceIconCatalog.search("puzzle").first?.name == "extension-puzzle")
        #expect(SpaceIconCatalog.search("coffee").first?.name == "cafe")
    }

    @MainActor
    @Test func everyCuratedIconLoadsFromTheBundle() {
        let missing = SpaceIconCatalog.symbols.filter { SpaceIconImage.load($0.name) == nil }
        #expect(missing.isEmpty, "Missing bundled icons: \(missing.map(\.name))")
    }

    @Test func everyLegacySymbolMapsIntoTheCatalog() {
        let names = Set(SpaceIconCatalog.symbols.map(\.name))
        let unknown = SpaceIconCatalog.legacySymbolMap.filter { !names.contains($0.value) }
        #expect(unknown.isEmpty, "Legacy mappings pointing outside the catalog: \(unknown)")
    }
}
