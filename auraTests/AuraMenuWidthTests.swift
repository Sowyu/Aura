import AppKit
@testable import Aura
import Testing

/// Panel sizing for the in-app menus. A fixed 240pt width middle-truncated real titles
/// such as "Always Open example.com in This Space" into unreadable stubs, so the width
/// now follows the widest row between a floor and a ceiling.
@MainActor
struct AuraMenuWidthTests {
    private func item(_ title: String, shortcut: String? = nil) -> AuraMenuItem {
        .item(title, shortcut: shortcut, action: {})
    }

    @Test func shortLabelsKeepTheDefaultWidth() {
        let width = AuraMenuMetrics.width(of: [item("New Tab", shortcut: "⌘T"), item("Reload")])
        #expect(width == AuraMenuMetrics.width)
    }

    @Test func aLongLabelWidensThePanel() {
        let long = item("Always Open some-quite-long-domain.example.com in This Space")
        let width = AuraMenuMetrics.width(of: [long])
        #expect(width > AuraMenuMetrics.width)
        #expect(width <= AuraMenuMetrics.maxWidth)
    }

    @Test func oneRunawayTitleCannotStretchThePanelPastTheCeiling() {
        let width = AuraMenuMetrics.width(of: [item(String(repeating: "wide ", count: 200))])
        #expect(width == AuraMenuMetrics.maxWidth)
    }

    @Test func theWidestRowWins() {
        let items = [item("Back"), item("Save Page As Something Rather Long..."), item("Print")]
        #expect(AuraMenuMetrics.width(of: items) == AuraMenuMetrics.width(of: [items[1]]))
    }

    @Test func aShortcutHintCountsTowardsTheWidth() {
        let bare = AuraMenuMetrics.width(of: [item(String(repeating: "x", count: 40))])
        let hinted = AuraMenuMetrics.width(of: [item(String(repeating: "x", count: 40), shortcut: "⇧⌘N")])
        #expect(hinted > bare)
    }
}
