import AppKit
import Foundation
import SwiftData

/// The saved half of a tab: its back/forward list and its scroll offset, written while
/// the app runs and read back the next time the tab needs a web view.
///
/// One per `TabManager`, over that window's context, because every write here rides on a
/// tab the window already has in front of it. Writes are coalesced and skipped when
/// nothing changed: a finished navigation, a tab switch and a maintenance pass can all
/// ask within a few milliseconds of each other, and each one re-encodes a blob that grows
/// with the tab's history.
@MainActor
final class TabSessionStore {
    /// How many tabs keep a saved session. The plan's number for scroll restoration, and
    /// there is no reason for the history blobs to outlive it: a tab nobody has touched
    /// in a hundred tab-switches reloads from its address without anyone noticing.
    static let maxSessions = 20
    /// A redirect chain finishes several navigations in a row; one write covers them.
    static let coalesceDelay: TimeInterval = 0.5

    private let modelContext: ModelContext
    private var pending: [UUID: DispatchWorkItem] = [:]
    /// False when the graph this context was built from has no session entity, which is
    /// every test container that names the entities it needs. Every call here is best
    /// effort, so it goes quiet rather than trapping inside Core Data.
    private let isAvailable: Bool

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        isAvailable = modelContext.container.schema.entities.contains { $0.name == "TabSession" }
    }

    // MARK: - Reading

    func session(for tabID: UUID) -> TabSession? {
        guard isAvailable else { return nil }
        var descriptor = FetchDescriptor<TabSession>(predicate: #Predicate { $0.tabID == tabID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Writing

    /// Coalesced: the last call inside `coalesceDelay` is the one that runs.
    func scheduleCapture(_ tab: Tab) {
        guard isAvailable else { return }
        let id = tab.id
        pending[id]?.cancel()
        let item = DispatchWorkItem { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Cleared before the guards below, so a tab that went away in the
                // meantime does not leave its work item in the table.
                self.pending[id] = nil
                guard let tab, !tab.isDeleted else { return }
                if self.capture(tab) { self.save() }
            }
        }
        pending[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceDelay, execute: item)
    }

    /// Writes what the tab's live page can tell us into its row, and returns whether any
    /// of it was new. Does not save, so a caller with several tabs pays for one save.
    ///
    /// `scroll` comes from the page's own probe rather than from WebKit: the session blob
    /// carries a scroll position too, but it is the one the page had when the blob was
    /// taken, which for a page captured at load time is the top.
    @discardableResult
    func capture(_ tab: Tab, scroll: CGPoint? = nil, scrollURL: URL? = nil) -> Bool {
        guard isAvailable, !tab.isPrivate, !tab.isDeleted, !tab.url.isOraInternal else { return false }

        let state = tab.browserPage?.sessionState
        let snapshot = tab.browserPage?.historySnapshot
        let entries = (snapshot?.isEmpty == false) ? snapshot?.encoded() : nil
        let offsetURL = (scroll != nil) ? (scrollURL ?? tab.url).absoluteString : nil
        guard state != nil || entries != nil || scroll != nil else { return false }

        guard let row = session(for: tab.id) else {
            let inserted = TabSession(
                tabID: tab.id,
                interactionState: state,
                historyEntries: entries,
                scrollX: Double(scroll?.x ?? 0),
                scrollY: Double(scroll?.y ?? 0),
                scrollURLString: offsetURL
            )
            modelContext.insert(inserted)
            return true
        }

        var changed = false
        if let state, state != row.interactionState {
            row.interactionState = state
            changed = true
        }
        if let entries, entries != row.historyEntries {
            row.historyEntries = entries
            changed = true
        }
        if let scroll, scroll.x != row.scrollX || scroll.y != row.scrollY || offsetURL != row.scrollURLString {
            row.scrollX = scroll.x
            row.scrollY = scroll.y
            row.scrollURLString = offsetURL
            changed = true
        }
        if changed { row.updatedAt = Date() }
        return changed
    }

    func save() {
        guard isAvailable else { return }
        saveOrLog(modelContext)
    }

    // MARK: - Sweeping

    /// Drops the sessions of tabs that are gone and, past the cap, the least recently
    /// written of what is left. Runs off the same minute tick as tab maintenance, so a
    /// closed tab's session outlives it by under a minute and never by a launch.
    func prune(liveTabIDs: Set<UUID>, limit: Int = maxSessions) {
        guard isAvailable else { return }
        guard let rows = try? modelContext.fetch(FetchDescriptor<TabSession>()) else { return }
        let doomed = Self.prunable(
            rows.map { (tabID: $0.tabID, updatedAt: $0.updatedAt) },
            liveTabIDs: liveTabIDs,
            limit: limit
        )
        guard !doomed.isEmpty else { return }
        for row in rows where doomed.contains(row.tabID) {
            modelContext.delete(row)
        }
        save()
    }

    /// Which saved sessions a sweep drops: every row whose tab is gone, then the oldest
    /// of the rest once there are more than `limit` of them.
    static func prunable(
        _ rows: [(tabID: UUID, updatedAt: Date)],
        liveTabIDs: Set<UUID>,
        limit: Int = maxSessions
    ) -> Set<UUID> {
        var doomed = Set(rows.map(\.tabID).filter { !liveTabIDs.contains($0) })
        let survivors = rows
            .filter { liveTabIDs.contains($0.tabID) }
            .sorted { $0.updatedAt > $1.updatedAt }
        if survivors.count > limit {
            doomed.formUnion(survivors.dropFirst(limit).map(\.tabID))
        }
        return doomed
    }
}
