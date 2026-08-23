import AppKit
import Foundation
import SwiftData
@preconcurrency import WebKit

// MARK: - Back/forward entries

/// One page in a tab's saved back/forward list.
///
/// Address and title only. `WKBackForwardListItem` offers nothing else, and a title is
/// the thing a back/forward menu has to show next to every row.
struct TabHistoryEntry: Codable, Equatable, Sendable {
    var urlString: String
    var title: String

    /// Nil when a stored address stopped parsing, which a menu renders as an unusable
    /// row rather than opening a search for it.
    var url: URL? { URL(string: urlString) }
}

/// A tab's back/forward list flattened for storage, plus where in it the tab is sitting.
///
/// Stored next to WebKit's own `interactionState` rather than instead of it. The blob is
/// what actually restores the history, but it is opaque (no titles to draw a menu from)
/// and a blob written by a different WebKit build can be ignored on assignment, so the
/// readable copy is both the menu's source and the evidence that the two disagree.
struct TabHistorySnapshot: Codable, Equatable, Sendable {
    /// How many pages either side of the current one are kept. Deeper than any menu
    /// shows, and shallow enough that the row stays cheap to write per navigation.
    static let sideLimit = 20

    var entries: [TabHistoryEntry] = []
    /// Index into `entries`. Out of range, `-1` included, means the tab has no current
    /// page, which is what an empty or truncated blob decodes to.
    var currentIndex: Int = -1

    /// Drops the far ends first: the pages nearest the current one are the ones a menu
    /// lists, and the ones a user reaches for.
    static func make(
        back: [TabHistoryEntry],
        current: TabHistoryEntry?,
        forward: [TabHistoryEntry],
        limit: Int = sideLimit
    ) -> TabHistorySnapshot {
        guard let current else { return TabHistorySnapshot() }
        let trimmedBack = Array(back.suffix(max(0, limit)))
        let trimmedForward = Array(forward.prefix(max(0, limit)))
        return TabHistorySnapshot(
            entries: trimmedBack + [current] + trimmedForward,
            currentIndex: trimmedBack.count
        )
    }

    var isEmpty: Bool { entries.isEmpty }

    var current: TabHistoryEntry? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
    }

    /// Nearest page first, the order a back menu lists them in.
    var back: [TabHistoryEntry] {
        guard entries.indices.contains(currentIndex) else { return [] }
        return entries[..<currentIndex].reversed()
    }

    /// Nearest page first, matching `back`.
    var forward: [TabHistoryEntry] {
        guard entries.indices.contains(currentIndex) else { return [] }
        return Array(entries[(currentIndex + 1)...])
    }

    /// Whether the saved list is a list *of* this address. A pinned tab reopens at the
    /// address it was pinned at rather than where it was left, and a page that moved
    /// under a single-page app can be ahead of the last list that was written, so a
    /// session is only the right thing to restore when the two agree.
    func belongs(to url: URL) -> Bool {
        current?.urlString == url.absoluteString
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Nil for anything that does not decode, so a row written by an older build is
    /// ignored rather than failing the restore it is only a hint for.
    static func decoded(from data: Data?) -> TabHistorySnapshot? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(TabHistorySnapshot.self, from: data)
    }
}

// MARK: - Model

/// What a tab needs to come back the way it was left: WebKit's session blob, the same
/// list in a readable form, and where the page was scrolled to.
///
/// Keyed by tab id instead of related to `Tab`, because a relationship would change the
/// shape of `Tab`, and `Tab` is the entity V2 and V3 of the schema describe. Rows are
/// bounded and swept by `TabSessionStore`, which is also what keeps a closed tab's
/// session from outliving it.
@Model
final class TabSession {
    @Attribute(.unique) var tabID: UUID
    /// WebKit's opaque `interactionState`: the back/forward list, which item is current,
    /// and the scroll position of that item. There is nothing to read inside it; it is
    /// restored by assignment, and WebKit decides whether it can. A blob it declines
    /// navigates nowhere and raises nothing, which is what the fallback in
    /// `startRestoredLoad` is watching for.
    @Attribute(.externalStorage) var interactionState: Data?
    /// `TabHistorySnapshot` as JSON.
    var historyEntries: Data?
    var scrollX: Double
    var scrollY: Double
    /// The address the offset belongs to. A page that is no longer the page that was
    /// scrolled gets no offset applied to it.
    var scrollURLString: String?
    /// When this row was last written. The sweep keeps the newest rows and drops the
    /// rest, so this is also "how recently was this tab used".
    var updatedAt: Date

    init(
        tabID: UUID,
        interactionState: Data? = nil,
        historyEntries: Data? = nil,
        scrollX: Double = 0,
        scrollY: Double = 0,
        scrollURLString: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.tabID = tabID
        self.interactionState = interactionState
        self.historyEntries = historyEntries
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.scrollURLString = scrollURLString
        self.updatedAt = updatedAt
    }

    var scrollOffset: CGPoint {
        CGPoint(x: scrollX, y: scrollY)
    }
}

// MARK: - Reading a live page

extension BrowserPage {
    /// WebKit's session blob for this view. A plain property read: no round trip to the
    /// web process, so it is safe to take on the way out of the app.
    var sessionState: Data? {
        auraWebView.interactionState as? Data
    }

    /// The live back/forward list, capped and in storage order.
    var historySnapshot: TabHistorySnapshot {
        let list = auraWebView.backForwardList
        return .make(
            back: list.backList.map(TabHistoryEntry.init),
            current: list.currentItem.map(TabHistoryEntry.init),
            forward: list.forwardList.map(TabHistoryEntry.init)
        )
    }
}

private extension TabHistoryEntry {
    init(_ item: WKBackForwardListItem) {
        self.init(urlString: item.url.absoluteString, title: item.title ?? "")
    }
}

// MARK: - Tab hooks

extension Tab {
    /// How long a restored session has to start navigating before the plain load takes
    /// over. Long enough to cover the privacy configuration the page waits on, short
    /// enough that a tab WebKit refused to restore does not sit blank.
    static let sessionRestoreTimeout: TimeInterval = 3

    /// One coalesced write per finished navigation, called from the tab's page delegate.
    /// Deliberately not called for title-only reports: a page that keeps renaming itself
    /// fires those many times a second and none of them move the back/forward list.
    func captureSession() {
        MainActor.assumeIsolated {
            tabManager?.sessionStore.scheduleCapture(self)
        }
    }

    /// Samples where the page is scrolled to and stores it against the current address.
    /// One `window.scrollY` read, cheap enough for a tab switch or a maintenance pass.
    func recordScrollOffset() {
        guard browserPage != nil, !isPrivate, !url.isOraInternal else { return }
        let target = url
        evaluateJavaScript("JSON.stringify([window.scrollX || 0, window.scrollY || 0])") { [weak self] result, error in
            guard let self,
                  error == nil,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let pair = try? JSONDecoder().decode([Double].self, from: data),
                  pair.count == 2
            else {
                return
            }
            MainActor.assumeIsolated {
                guard let store = self.tabManager?.sessionStore else { return }
                if store.capture(self, scroll: CGPoint(x: pair[0], y: pair[1]), scrollURL: target) {
                    store.save()
                }
            }
        }
    }

    /// Where a restored tab picks up.
    ///
    /// Assigning WebKit's session blob brings the back/forward list back and loads the
    /// item the tab was on, which is why it replaces the plain load rather than joining
    /// it. Three things send a tab down the plain path instead: being sent somewhere new,
    /// having no saved session, and a saved session whose current page is not where this
    /// tab is meant to open (a pinned tab reopens at the address it was pinned at). A
    /// blob WebKit declines to decode navigates nowhere at all, so the timeout below is
    /// the last fallback.
    func startRestoredLoad(page: BrowserPage, loading: URL?) {
        let request = URLRequest(url: loading ?? launchURL)
        guard loading == nil, !isPrivate, let state = restorableSessionState() else {
            page.load(request)
            return
        }

        page.restoreSession(state)
        DispatchQueue.main.asyncAfter(deadline: .now() + Tab.sessionRestoreTimeout) { [weak page] in
            guard let page, page.currentURL == nil, !page.isLoading else { return }
            page.load(request)
        }
    }

    /// The saved blob, when there is one and it is a list of the page this tab is about
    /// to open. Every caller is already on the main queue; the tab itself is not
    /// main-actor bound, but the store it reads from is.
    private func restorableSessionState() -> Data? {
        MainActor.assumeIsolated { () -> Data? in
            guard let session = tabManager?.sessionStore.session(for: id),
                  let state = session.interactionState,
                  TabHistorySnapshot.decoded(from: session.historyEntries)?.belongs(to: launchURL) == true
            else {
                return nil
            }
            return state
        }
    }
}
