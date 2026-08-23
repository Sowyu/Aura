import Foundation

/// One row of a back or forward menu: what to draw, and how far to travel.
struct NavigationHistoryRow: Equatable, Identifiable {
    /// Pages away from the one the tab is on, counting from 1. Always positive; the menu
    /// it belongs to is what says which direction.
    let steps: Int
    /// Already truncated, so the panel is sized by the same string the row draws.
    let title: String
    let urlString: String

    var id: Int { steps }

    /// Nil when a stored address stopped parsing, which the menu treats as a row that
    /// cannot be opened rather than as a search for its text.
    var url: URL? { URL(string: urlString) }
}

/// Turns a tab's back/forward list into menu rows.
///
/// A tab with a web view has WebKit's own list; a hibernated or just-restored tab has
/// only the copy written to its session row. Both reach here as `TabHistoryEntry` values
/// ordered nearest-page-first, so one function draws both and the menu cannot say two
/// different things depending on whether the page happens to be live.
enum NavigationHistoryMenu {
    /// Titles longer than this are clipped. Wide enough for a headline, narrow enough
    /// that one row cannot stretch the panel to its ceiling on its own.
    static let titleLimit = 50
    /// Rows in one menu. Deeper than anyone walks by pointer, and the rest of the list is
    /// still there for repeated ⌘[.
    static let rowLimit = 12

    /// `entries` nearest page first, which is the order both sources hand them over in.
    static func rows(from entries: [TabHistoryEntry], limit: Int = rowLimit) -> [NavigationHistoryRow] {
        entries.prefix(max(0, limit)).enumerated().map { index, entry in
            NavigationHistoryRow(
                steps: index + 1,
                title: displayTitle(for: entry),
                urlString: entry.urlString
            )
        }
    }

    /// The page's title, or its address when it never reported one: a blank row in a
    /// back menu is unusable, and an address at least says where it goes.
    static func displayTitle(for entry: TabHistoryEntry, limit: Int = titleLimit) -> String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? entry.urlString : trimmed
        guard text.count > limit, limit > 0 else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
