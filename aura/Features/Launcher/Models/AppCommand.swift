import AppKit
import Foundation

/// One command the launcher can run: the words the menu bar uses for it, the binding it
/// shows, and the event the menu item posts.
///
/// The table below is the only place those three facts sit together. A row posts the same
/// notification the menu item does rather than reaching into a window itself, so a
/// command lands on whichever window is in front exactly the way ⌘R does, and a command
/// that is only handled by some windows keeps behaving that way.
struct AppCommand: Identifiable, Equatable {
    let id: String
    let title: String
    let notification: Notification.Name
    /// The binding this command shows, when it has one. Read live, so rebinding it in
    /// Settings changes what the palette prints.
    let shortcut: KeyboardShortcutDefinition?

    init(
        _ id: String,
        _ title: String,
        _ notification: Notification.Name,
        shortcut: KeyboardShortcutDefinition? = nil
    ) {
        self.id = id
        self.title = title
        self.notification = notification
        self.shortcut = shortcut
    }

    var chord: String? { shortcut?.currentChord.display }

    @MainActor
    func run() {
        NotificationCenter.default.post(name: notification, object: NSApp.keyWindow)
    }
}

/// Every app command the launcher offers, and the matching that decides when to offer it.
enum AppCommandCatalog {
    /// Turns the omnibox into a command palette, spelled the way Raycast and VS Code
    /// spell it.
    static let marker: Character = ">"
    /// Rows one query may produce. The suggestion list does not scroll, so a palette that
    /// listed all of these would run off the bottom of the window.
    static let limit = 8
    /// Shortest query that earns command rows without the marker. One letter matches
    /// most of the table and would bury the row that opens what was typed.
    static let looseMinimumLength = 2
    /// What a command row is worth when the user did not ask for commands. Below any
    /// history or open-tab row, so a command never outranks the page that was meant.
    static let looseScore: Float = 0.5

    static let all: [AppCommand] = [
        AppCommand("command.newTab", "New Tab", .newTab, shortcut: KeyboardShortcuts.Tabs.new),
        AppCommand("command.closeTab", "Close Tab", .closeActiveTab, shortcut: KeyboardShortcuts.Tabs.close),
        AppCommand(
            "command.reopenTab", "Reopen Closed Tab", .restoreLastTab,
            shortcut: KeyboardShortcuts.Tabs.restore
        ),
        AppCommand("command.pinTab", "Pin Tab", .togglePinTab, shortcut: KeyboardShortcuts.Tabs.pin),
        AppCommand("command.nextTab", "Next Tab", .nextTab, shortcut: KeyboardShortcuts.Tabs.next),
        AppCommand(
            "command.previousTab", "Previous Tab", .previousTab,
            shortcut: KeyboardShortcuts.Tabs.previous
        ),
        AppCommand("command.reload", "Reload Page", .reloadPage, shortcut: KeyboardShortcuts.Navigation.reload),
        AppCommand(
            "command.hardReload", "Hard Reload", .hardReloadPage,
            shortcut: KeyboardShortcuts.Navigation.hardReload
        ),
        AppCommand("command.back", "Back", .goBack, shortcut: KeyboardShortcuts.Navigation.back),
        AppCommand("command.forward", "Forward", .goForward, shortcut: KeyboardShortcuts.Navigation.forward),
        AppCommand("command.clearCache", "Clear Cache & Reload", .clearCacheAndReload),
        AppCommand("command.clearCookies", "Clear Cookies & Reload", .clearCookiesAndReload),
        AppCommand("command.find", "Find in Page", .findInPage, shortcut: KeyboardShortcuts.Edit.find),
        AppCommand("command.copyURL", "Copy URL", .copyAddressURL, shortcut: KeyboardShortcuts.Address.copyURL),
        AppCommand("command.addBookmark", "Add Bookmark", .addBookmark, shortcut: KeyboardShortcuts.Bookmarks.add),
        AppCommand("command.readingList", "Add to Reading List", .addToReadingList),
        AppCommand(
            "command.bookmarksBar", "Show Bookmarks Bar", .toggleBookmarksBar,
            shortcut: KeyboardShortcuts.Bookmarks.toggleBar
        ),
        AppCommand("command.history", "Show All History", .showHistoryPanel, shortcut: KeyboardShortcuts.History.show),
        AppCommand("command.downloads", "Show Downloads", .showDownloadsPanel),
        AppCommand("command.savePage", "Save Page As", .savePageAs),
        AppCommand("command.screenshot", "Save Screenshot", .savePageScreenshot),
        AppCommand("command.viewSource", "View Source", .viewPageSource),
        AppCommand("command.reader", "Reader", .showReaderMode),
        AppCommand("command.zoomIn", "Zoom In", .zoomIn, shortcut: KeyboardShortcuts.Zoom.zoomIn),
        AppCommand("command.zoomOut", "Zoom Out", .zoomOut, shortcut: KeyboardShortcuts.Zoom.zoomOut),
        AppCommand("command.zoomReset", "Reset Zoom", .zoomReset, shortcut: KeyboardShortcuts.Zoom.reset),
        AppCommand(
            "command.toggleJavaScript", "Toggle JavaScript for This Site", .toggleSiteJavaScript,
            shortcut: KeyboardShortcuts.Privacy.toggleJavaScript
        ),
        AppCommand(
            "command.toggleSidebar", "Toggle Sidebar", .toggleSidebar,
            shortcut: KeyboardShortcuts.App.toggleSidebar
        ),
        AppCommand("command.sidebarSide", "Switch Sidebar Side", .toggleSidebarPosition),
        AppCommand(
            "command.toggleToolbar", "Toggle Toolbar", .toggleToolbar,
            shortcut: KeyboardShortcuts.App.toggleToolbar
        ),
        AppCommand(
            "command.compactMode", "Toggle Compact Mode", .toggleCompactMode,
            shortcut: KeyboardShortcuts.Window.toggleCompactMode
        ),
        AppCommand("command.fullURL", "Toggle Full URL", .toggleFullURL),
        AppCommand("command.settings", "Settings", .openSettingsTab, shortcut: KeyboardShortcuts.App.preferences),
        AppCommand("command.checkUpdates", "Check for Updates", .checkForUpdates)
    ]

    /// The palette query inside `text`, or nil when the text is not one. `>` on its own
    /// means "show me everything".
    static func paletteQuery(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == marker else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Commands to offer for `query`.
    ///
    /// With the marker, an empty query lists the table and a match anywhere in a title
    /// counts, because the user has already said they want commands. Without it, only a
    /// word of the title starting with the query counts: typing an address must not bury
    /// the row that opens it under commands that merely contain the same letters.
    static func matches(_ query: String, palette: Bool, limit: Int = limit) -> [AppCommand] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return palette ? Array(all.prefix(limit)) : [] }
        guard palette || needle.count >= looseMinimumLength else { return [] }

        let hits = all.filter { command in
            let title = command.title.lowercased()
            return palette ? title.contains(needle) : startsAWord(of: title, with: needle)
        }
        // Titles that start with the query first, the rest in table order, which groups
        // them the way the menus do. Partitioned rather than sorted: `sort` is not stable
        // and would shuffle equally good rows between keystrokes.
        let leading = hits.filter { $0.title.lowercased().hasPrefix(needle) }
        let rest = hits.filter { !$0.title.lowercased().hasPrefix(needle) }
        return Array((leading + rest).prefix(limit))
    }

    private static func startsAWord(of title: String, with needle: String) -> Bool {
        title.split(separator: " ").contains { $0.hasPrefix(needle) }
    }
}

@MainActor
extension LauncherSuggestion {
    /// A command as a launcher row: the chord prints on the right, and running the row
    /// posts exactly what the menu item posts.
    init(command: AppCommand, query: String, palette: Bool) {
        self.init(
            type: .command,
            title: command.title,
            name: command.chord,
            score: palette ? nil : AppCommandCatalog.looseScore,
            completingText: query,
            action: { command.run() }
        )
    }
}
