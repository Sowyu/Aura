import AppKit
@testable import Aura
import Foundation
import SwiftUI
import Testing

/// The back/forward menu's row model, built from the live list and from the saved one.
@Suite("Back/forward history menu")
struct NavigationHistoryMenuTests {
    private func entries(_ prefix: String, _ count: Int) -> [TabHistoryEntry] {
        (0 ..< count).map {
            TabHistoryEntry(urlString: "https://\(prefix).example/\($0)", title: "\(prefix) \($0)")
        }
    }

    private func snapshot() -> TabHistorySnapshot {
        TabHistorySnapshot.make(
            back: entries("back", 3),
            current: TabHistoryEntry(urlString: "https://example.com/now", title: "Now"),
            forward: entries("forward", 2)
        )
    }

    @Test("Rows count away from the page the tab is on, nearest first")
    func stepsCountFromTheCurrentPage() {
        let rows = NavigationHistoryMenu.rows(from: snapshot().back)

        #expect(rows.map(\.steps) == [1, 2, 3])
        // The snapshot lists the back side nearest first, which is the page one ⌘[ away.
        #expect(rows.first?.urlString == "https://back.example/2")
        #expect(rows.last?.urlString == "https://back.example/0")
    }

    @Test("The forward side is numbered the same way")
    func forwardRows() {
        let rows = NavigationHistoryMenu.rows(from: snapshot().forward)

        #expect(rows.map(\.steps) == [1, 2])
        #expect(rows.first?.urlString == "https://forward.example/0")
    }

    @Test("A tab with no web view draws the same menu from its saved session")
    func savedSessionProducesTheSameRows() throws {
        let live = snapshot()
        let data = try #require(live.encoded())
        let restored = try #require(TabHistorySnapshot.decoded(from: data))

        #expect(NavigationHistoryMenu.rows(from: restored.back) == NavigationHistoryMenu.rows(from: live.back))
        #expect(NavigationHistoryMenu.rows(from: restored.forward) == NavigationHistoryMenu.rows(from: live.forward))
    }

    @Test("A page that reported no title shows its address instead")
    func untitledPagesShowTheirAddress() {
        let entry = TabHistoryEntry(urlString: "https://example.com/paper.pdf", title: "  ")

        #expect(NavigationHistoryMenu.displayTitle(for: entry) == "https://example.com/paper.pdf")
    }

    @Test("A long title is clipped to the row width")
    func longTitlesAreTruncated() {
        let entry = TabHistoryEntry(urlString: "https://example.com", title: String(repeating: "a", count: 120))
        let title = NavigationHistoryMenu.displayTitle(for: entry)

        #expect(title.count == NavigationHistoryMenu.titleLimit)
        #expect(title.hasSuffix("…"))
    }

    @Test("A short title is left alone")
    func shortTitlesSurvive() {
        let entry = TabHistoryEntry(urlString: "https://example.com", title: "Example")

        #expect(NavigationHistoryMenu.displayTitle(for: entry) == "Example")
    }

    @Test("The menu stops well before the end of a deep list")
    func rowsAreCapped() {
        let deep = entries("back", 40)

        #expect(NavigationHistoryMenu.rows(from: deep).count == NavigationHistoryMenu.rowLimit)
        #expect(NavigationHistoryMenu.rows(from: []).isEmpty)
    }

    @Test("A stored address that stopped parsing gives a row with no destination")
    func unparsableAddressesHaveNoURL() {
        let rows = NavigationHistoryMenu.rows(from: [TabHistoryEntry(urlString: "", title: "Gone")])

        #expect(rows.first?.url == nil)
    }
}

/// ⇧⌘R. The request is what carries the "do not use the cache" part, so that is what is
/// checked; the reload itself is one call on the web view.
@Suite("Hard reload")
struct HardReloadTests {
    @Test("The request skips the local cache and keeps the address")
    func requestIgnoresTheCache() throws {
        let url = try #require(URL(string: "https://example.com/page?q=1"))
        let request = BrowserPage.hardReloadRequest(for: url)

        #expect(request.url == url)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }
}

/// The shortcut catalogue. Two commands on one chord means AppKit picks between them by
/// menu order, which is not a decision anyone made.
@Suite("Keyboard shortcut table")
@MainActor
struct KeyboardShortcutTableTests {
    @Test("No two shortcuts ship on the same chord")
    func defaultChordsAreUnique() {
        var owners: [String: String] = [:]
        for shortcut in KeyboardShortcuts.allShortcuts {
            let chord = shortcut.defaultChord.display
            if let existing = owners[chord] {
                Issue.record("\(chord) is on both \(existing) and \(shortcut.id)")
            }
            owners[chord] = shortcut.id
        }
    }

    @Test("Ids are unique, so a binding belongs to one command")
    func idsAreUnique() {
        let ids = KeyboardShortcuts.allShortcuts.map(\.id)

        #expect(Set(ids).count == ids.count)
    }

    @Test("A retired id is gone from the catalogue and dropped from stored bindings")
    func retiredBindingsAreDropped() {
        let retired = "developer.reloadIgnoringCache"
        #expect(CustomKeyboardShortcutManager.retiredShortcutIDs.contains(retired))
        #expect(!KeyboardShortcuts.allShortcuts.contains { $0.id == retired })

        let chord = KeyChord(keyEquivalent: .init("r"), modifiers: [.command, .shift])
        let stored = [retired: chord, "tabs.new": chord, "extensions.ublock.toggle": chord]
        let kept = CustomKeyboardShortcutManager.withoutRetired(stored)

        #expect(kept[retired] == nil)
        #expect(kept["tabs.new"] == chord)
        // An extension's own binding is not a built-in id and must survive the sweep.
        #expect(kept["extensions.ublock.toggle"] == chord)
    }
}

/// The launcher's command source: when it offers rows, and what those rows post.
@Suite("Command palette")
@MainActor
struct AppCommandCatalogTests {
    /// Every event the window routing tables handle, from `OraRoot.events` and
    /// `BrowserView`'s own `onReceive` block. A command posting anything else would
    /// disappear into the notification centre without a word.
    private let routed: Set<String> = [
        "NewTab", "CloseActiveTab", "RestoreLastTab", "TogglePinTab", "NextTab", "PreviousTab",
        "ReloadPage", "HardReloadPage", "GoBack", "GoForward",
        "ClearCacheAndReload", "ClearCookiesAndReload",
        "FindInPage", "FindNext", "FindPrevious", "CopyAddressURL",
        "AddBookmark", "AddToReadingList", "ToggleBookmarksBar",
        "ShowHistoryPanel", "ShowDownloadsPanel",
        "SavePageAs", "SavePageScreenshot", "ViewPageSource", "ShowReaderMode",
        "ZoomIn", "ZoomOut", "ZoomReset", "ToggleSiteJavaScript",
        "ToggleSidebar", "ToggleSidebarPosition", "ToggleToolbar", "ToggleCompactMode",
        "ToggleFullURL", "openSettingsTab", "CheckForUpdates", "ShowLauncher"
    ]

    @Test("Every command posts an event a window handles")
    func commandsPostRoutedEvents() {
        for command in AppCommandCatalog.all {
            #expect(routed.contains(command.notification.rawValue), "\(command.id) posts nothing anyone hears")
        }
    }

    @Test("Ids are unique and every row has words to show")
    func rowsAreWellFormed() {
        let ids = AppCommandCatalog.all.map(\.id)

        #expect(Set(ids).count == ids.count)
        #expect(AppCommandCatalog.all.allSatisfy { !$0.title.isEmpty })
    }

    @Test("A row prints the binding its command actually has")
    func chordsComeFromTheShortcutTable() {
        for command in AppCommandCatalog.all where command.shortcut != nil {
            #expect(command.chord?.isEmpty == false)
        }
        #expect(AppCommandCatalog.all.first { $0.id == "command.readingList" }?.chord == nil)

        let reload = AppCommandCatalog.all.first { $0.id == "command.hardReload" }
        #expect(reload?.shortcut?.defaultChord.display == "⇧⌘R")
        #expect(reload?.notification == .hardReloadPage)
    }

    @Test("The marker is what turns the omnibox into a palette")
    func paletteQueryParsing() {
        #expect(AppCommandCatalog.paletteQuery(">") == "")
        #expect(AppCommandCatalog.paletteQuery("> zoom ") == "zoom")
        #expect(AppCommandCatalog.paletteQuery("  >zoom") == "zoom")
        #expect(AppCommandCatalog.paletteQuery("zoom") == nil)
        #expect(AppCommandCatalog.paletteQuery("example.com/>x") == nil)
        #expect(AppCommandCatalog.paletteQuery("") == nil)
    }

    @Test("The bare marker lists the table, capped to what the list can draw")
    func emptyPaletteQueryListsCommands() {
        let rows = AppCommandCatalog.matches("", palette: true)

        #expect(rows.count == AppCommandCatalog.limit)
        #expect(rows.first == AppCommandCatalog.all.first)
    }

    @Test("A palette query matches anywhere in a title, best first")
    func paletteMatching() {
        let rows = AppCommandCatalog.matches("zoom", palette: true)

        #expect(rows.contains { $0.id == "command.zoomIn" })
        #expect(rows.contains { $0.id == "command.zoomReset" })
        // "Zoom In" starts with the query, "Reset Zoom" only contains it.
        #expect(rows.first?.title.hasPrefix("Zoom") == true)
        #expect(AppCommandCatalog.matches("oom", palette: true).isEmpty == false)
    }

    @Test("Without the marker only a word of the title counts, and never on one letter")
    func looseMatchingIsStrict() {
        #expect(AppCommandCatalog.matches("r", palette: false).isEmpty)
        #expect(AppCommandCatalog.matches("oom", palette: false).isEmpty)
        #expect(AppCommandCatalog.matches("", palette: false).isEmpty)

        let rows = AppCommandCatalog.matches("reload", palette: false)
        #expect(rows.contains { $0.id == "command.hardReload" })
        #expect(rows.contains { $0.id == "command.reload" })
    }

    @Test("No query returns more rows than the list can show")
    func matchesRespectTheLimit() {
        #expect(AppCommandCatalog.matches("t", palette: true).count <= AppCommandCatalog.limit)
    }
}
