import Foundation

/// What each tab is searching for, kept outside the find bar so switching tabs and
/// coming back does not wipe the term. The bar itself is mounted once per window, in
/// `BrowserView`, rather than inside the per-tab web content view that SwiftUI rebuilds
/// on every switch.
@Observable
@MainActor
final class FindManager {
    /// Keyed by tab id, which is unique across windows, so one instance serves them all.
    static let shared = FindManager()

    struct Session: Equatable {
        var query: String = ""
        /// False only after a search that found nothing; a fresh session shows no badge.
        var matched: Bool = true
    }

    /// ponytail: a closed tab leaves its query behind. One short string per tab id;
    /// clear it from `TabManager.closeTab` if a session ever grows past that.
    private var sessions: [UUID: Session] = [:]

    func session(for tabID: UUID) -> Session {
        sessions[tabID] ?? Session()
    }

    /// Records the term and runs the search. An empty term clears the highlight.
    func search(_ query: String, in tab: Tab, forward: Bool = true) {
        var session = self.session(for: tab.id)
        session.query = query
        session.matched = true
        sessions[tab.id] = session

        guard let page = tab.browserPage else { return }
        let controller = FindController(page: page)
        guard !query.isEmpty else {
            controller.clear()
            return
        }

        controller.find(query, forward: forward) { matched in
            MainActor.assumeIsolated {
                FindManager.shared.sessions[tab.id]?.matched = matched
            }
        }
    }

    /// ⌘G / ⇧⌘G: step through the term the tab already has. Returns false when there is
    /// nothing to step through, so the caller can leave the bar closed.
    @discardableResult
    func step(in tab: Tab, forward: Bool) -> Bool {
        let query = session(for: tab.id).query
        guard !query.isEmpty else { return false }
        search(query, in: tab, forward: forward)
        return true
    }

    func close(_ tab: Tab) {
        guard let page = tab.browserPage else { return }
        FindController(page: page).clear()
    }
}
