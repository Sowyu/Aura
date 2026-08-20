import Combine
import Foundation
import SwiftUI

struct EmojiCategory: Identifiable {
    let id = UUID()
    let category: String
    let emojis: [EmojiItem]
}

struct EmojiItem: Identifiable {
    let id = UUID()
    let emoji: String
    let name: String
    let code: [String]
    /// Skin-tone and hair forms of `emoji`; empty when the emoji has no variants.
    var variants: [EmojiItem] = []
}

// MARK: - Variant grouping

/// Collapses the flat bundled emoji list into base emoji plus their variant forms.
enum EmojiVariants {
    static let skinTones: Set<String> = ["1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF"]
    static let hairStyles: Set<String> = ["1F9B0", "1F9B1", "1F9B2", "1F9B3"]

    /// Key shared by an emoji and all of its variants: skin-tone modifiers, variation
    /// selectors and ZWJ hair components are stripped out.
    static func baseKey(for code: [String]) -> String {
        let stripped = code.map { $0.uppercased() }
            .filter { $0 != "FE0F" && !skinTones.contains($0) }
        var result: [String] = []
        var index = 0
        while index < stripped.count {
            if stripped[index] == "200D", index + 1 < stripped.count, hairStyles.contains(stripped[index + 1]) {
                index += 2
                continue
            }
            result.append(stripped[index])
            index += 1
        }
        return result.joined(separator: "-")
    }

    /// Returns one entry per base emoji, in source order, with the remaining forms
    /// of that emoji attached as `variants`.
    static func group(_ items: [EmojiItem]) -> [EmojiItem] {
        var order: [String] = []
        var buckets: [String: [EmojiItem]] = [:]
        for item in items {
            let key = item.code.isEmpty ? item.emoji : baseKey(for: item.code)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let bucket = buckets[key], var base = bucket.first else { return nil }
            base.variants = Array(bucket.dropFirst())
            return base
        }
    }
}

// MARK: - View model

class EmojiViewModel: ObservableObject {
    @Published var categories: [EmojiCategory] = []
    @Published var searchText: String = ""
    @Published var selectedCategory: String?
    @Published var isLoading: Bool = true
    @Published var error: String?

    private var allEmojis: [EmojiItem] = []

    init() {
        loadEmojis()
    }

    private func loadEmojis() {
        guard let url = Bundle.main.url(forResource: "emoji-set", withExtension: "json") else {
            error = "JSON file not found."
            isLoading = false
            return
        }

        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let emojisDict = root["emojis"] as? [String: Any]
            else {
                throw NSError(domain: "Invalid JSON structure", code: 0)
            }

            var result: [EmojiCategory] = []
            for category in Self.categoryOrder {
                guard let subcategories = emojisDict[category] as? [String: Any] else { continue }
                let subcategoryOrder = getSubcategoryOrder(for: category)
                let flat: [EmojiItem] =
                    subcategoryOrder.isEmpty
                        ? extractEmojis(from: subcategories)
                        : subcategoryOrder.flatMap { subcat -> [EmojiItem] in
                            guard let items = subcategories[subcat] as? [[String: Any]] else { return [] }
                            return items.compactMap(EmojiItem.init(from:))
                        }
                result.append(EmojiCategory(category: category, emojis: EmojiVariants.group(flat)))
            }

            categories = result
            allEmojis = result.flatMap(\.emojis)
            selectedCategory = categories.first?.category
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private static let categoryOrder = [
        "Smileys, Emotion, People & Body",
        "Animals & Nature",
        "Food & Drink",
        "Travel, Places & Activities",
        "Objects",
        "Symbols",
        "Flags"
    ]

    private func extractEmojis(from subcategories: [String: Any]) -> [EmojiItem] {
        subcategories.values.compactMap { $0 as? [[String: Any]] }
            .flatMap { $0.compactMap(EmojiItem.init(from:)) }
    }

    private func getSubcategoryOrder(for category: String) -> [String] {
        switch category {
        case "Smileys, Emotion, People & Body":
            return [
                "face-smiling", "face-affection", "face-tongue", "face-hand",
                "face-neutral-skeptical", "face-sleepy", "face-unwell",
                "face-hat", "face-glasses", "face-concerned", "face-negative",
                "face-costume", "cat-face", "monkey-face", "emotion",
                "hand-fingers-open", "hand-fingers-partial", "hand-single-finger",
                "hand-fingers-closed", "hands", "hand-prop", "body-parts",
                "person", "person-gesture", "person-role", "person-fantasy",
                "person-activity", "person-sport", "person-resting",
                "family", "person-symbol"
            ]
        case "Animals & Nature":
            return [
                "animal-mammal", "animal-bird", "animal-amphibian", "animal-reptile",
                "animal-marine", "animal-bug", "plant-flower", "plant-other"
            ]
        case "Food & Drink":
            return [
                "food-fruit", "food-vegetable", "food-prepared", "food-asian",
                "food-marine", "food-sweet", "drink"
            ]
        default:
            return []
        }
    }

    var filteredEmojis: [EmojiItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return
                selectedCategory
                    .flatMap { category in categories.first(where: { $0.category == category })?.emojis }
                    ?? []
        }
        return SpaceIconSearch.rank(query: query, in: allEmojis) {
            [$0.name, EmojiKeywords.map[$0.emoji] ?? ""]
        }
    }
}

private extension EmojiItem {
    init?(from dict: [String: Any]) {
        guard let emoji = dict["emoji"] as? String,
              let name = dict["name"] as? String
        else {
            return nil
        }
        self.init(emoji: emoji, name: name, code: dict["code"] as? [String] ?? [])
    }
}
