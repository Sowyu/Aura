import Foundation
import SwiftData

// MARK: - BrowsingContainer

/// A Firefox-style Multi-Account Container: a named, coloured cookie jar.
///
/// Independent of spaces on purpose. A space (`TabContainer`) can point at one as its
/// default for new tabs, and any single tab can sit in a different one. `nil` on a tab
/// means the shared default store, which is Firefox's "No container".
@Model
final class BrowsingContainer: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    /// SF Symbol drawn on the tab strip and in the picker.
    var iconSymbol: String
    /// Position in the settings list, dense and ascending.
    var order: Int
    var createdAt: Date
    /// Identifier of the `WKWebsiteDataStore` this container owns. Separate from `id` so
    /// the migration can hand a container the store a space was already using.
    var storeIdentifier: UUID

    @Relationship var tabs: [Tab] = []

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = BrowsingContainer.palette[0],
        iconSymbol: String = BrowsingContainer.defaultIconSymbol,
        order: Int = 0,
        storeIdentifier: UUID = UUID()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.iconSymbol = iconSymbol
        self.order = order
        self.createdAt = Date()
        self.storeIdentifier = storeIdentifier
    }

    /// Firefox's eight container colours, in Firefox's order.
    static let palette: [String] = [
        "#37ADFF", // blue
        "#00C79A", // turquoise
        "#51CD49", // green
        "#FFCB00", // yellow
        "#FF9F00", // orange
        "#FF613D", // red
        "#FF4BDA", // pink
        "#AF51F5"  // purple
    ]

    /// Firefox's container icon names mapped onto the closest SF Symbol.
    static let iconSymbols: [String: String] = [
        "fingerprint": "touchid",
        "briefcase": "briefcase.fill",
        "dollar": "dollarsign.circle.fill",
        "cart": "cart.fill",
        "vacation": "beach.umbrella.fill",
        "gift": "gift.fill",
        "food": "fork.knife",
        "fruit": "carrot.fill",
        "pet": "pawprint.fill",
        "tree": "tree.fill",
        "chill": "snowflake",
        "circle": "circle.fill"
    ]

    /// The same set as `iconSymbols`, in Firefox's picker order.
    static let icons: [String] = [
        "fingerprint", "briefcase", "dollar", "cart", "circle", "gift",
        "vacation", "food", "fruit", "pet", "tree", "chill"
    ].compactMap { iconSymbols[$0] }

    static let defaultIconSymbol = "circle.fill"

    /// Next colour in the palette for a list that already has `count` containers, so two
    /// containers made back to back never look alike.
    static func nextColorHex(forExisting count: Int) -> String {
        palette[count % palette.count]
    }
}
