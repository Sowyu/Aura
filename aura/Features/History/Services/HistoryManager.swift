import Foundation
import os.log
import SwiftData

private let logger = Logger(subsystem: "com.aurabrowser.app", category: "HistoryManager")

/// One page of visits plus whether the store had more rows behind it.
struct HistoryPage {
    let items: [History]
    let hasMore: Bool

    static let empty = HistoryPage(items: [], hasMore: false)
}

/// How far back the history panel looks. Ported from Nook's `TimeRange`
/// (`Nook/Components/Sidebar/Menu/SidebarMenuHistoryTab.swift`) by Maciek Bagiński,
/// GPL-3.0, with the day counts replaced by calendar boundaries so "Today" means today
/// rather than the last 24 hours.
enum HistoryRange: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "This Week"
        case .month: return "This Month"
        case .all: return "All Time"
        }
    }

    /// Oldest `lastAccessedAt` the range admits. Nil means no lower bound.
    func cutoff(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
        case .month:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        case .all:
            return nil
        }
    }
}

/// Every visit in one space, on the store the window was built with.
///
/// A private window is handed a container backed by `isStoredInMemoryOnly`, so its
/// visits never touch `OraData.sqlite` and go away with the window. They are still
/// visible in that window's own history menu while it is open, which is what an
/// in-memory store means; nothing is written to disk and nothing crosses into a
/// normal window.
@Observable
@MainActor
final class HistoryManager {
    let modelContainer: ModelContainer
    let modelContext: ModelContext

    init(modelContainer: ModelContainer, modelContext: ModelContext) {
        self.modelContainer = modelContainer
        self.modelContext = modelContext
    }

    func record(
        title: String,
        url: URL,
        faviconURL: URL? = nil,
        faviconLocalFile: URL? = nil,
        container: TabContainer
    ) {
        // aura:// pages are chrome, not visits. Guarded here rather than at each caller
        // so nothing can slip the new-tab page into the history list.
        guard !url.isOraInternal else { return }

        let urlString = url.absoluteString
        let containerId = container.id

        // Keep history entries scoped to a space so visits from different spaces
        // do not overwrite each other or become unreachable from space filters.
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { history in
                history.urlString == urlString && history.container?.id == containerId
            },
            sortBy: [.init(\.lastAccessedAt, order: .reverse)]
        )

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.visitCount += 1
            existing.lastAccessedAt = Date() // update last visited time
        } else {
            let now = Date()
            let defaultFaviconURL = FaviconService.shared.faviconURL(for: url.host ?? "")
            let resolvedFaviconURL = faviconURL ?? defaultFaviconURL ?? url
            modelContext.insert(History(
                url: url,
                title: title,
                faviconURL: resolvedFaviconURL,
                faviconLocalFile: faviconLocalFile,
                createdAt: now,
                lastAccessedAt: now,
                visitCount: 1,
                container: container
            ))
        }

        try? modelContext.save()
    }

    /// Newest visits in one space. Bounded at the store, so the toolbar's history menu
    /// never materialises the whole table the way a plain `@Query` did.
    func recent(limit: Int, in containerId: UUID) -> [History] {
        var descriptor = FetchDescriptor<History>(
            predicate: #Predicate { $0.container?.id == containerId },
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            logger.error("Error fetching recent history: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    func search(_ text: String, activeContainerId: UUID) -> [History] {
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        // Matching in the predicate keeps the whole history table out of memory; the
        // launcher only ever shows a handful of rows, so a bounded fetch is enough.
        let inContainer = #Predicate<History> { $0.container?.id == activeContainerId }
        let matchesText = #Predicate<History> {
            $0.container?.id == activeContainerId &&
                ($0.urlString.localizedStandardContains(trimmedText) ||
                    $0.title.localizedStandardContains(trimmedText))
        }
        var descriptor = FetchDescriptor<History>(
            predicate: trimmedText.isEmpty ? inContainer : matchesText,
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            logger.error("Error fetching history: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: - Panel paging

    /// One page of visits in one space, newest first, optionally filtered by text and by
    /// how far back the panel is looking. Offset paging rather than a cursor: the panel
    /// appends pages and the sort key is stable while it is open.
    ///
    /// Ported behaviour from Nook's `SidebarMenuHistoryTab` by Maciek Bagiński, GPL-3.0;
    /// the query itself stays Aura's, matching inside the predicate so the whole table
    /// never lands in memory.
    func page(
        matching query: String = "",
        range: HistoryRange = .all,
        in containerId: UUID,
        offset: Int,
        limit: Int,
        now: Date = Date()
    ) -> HistoryPage {
        guard limit > 0, offset >= 0 else { return .empty }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matchAll = trimmed.isEmpty
        let cutoff = range.cutoff(from: now) ?? .distantPast

        var descriptor = FetchDescriptor<History>(
            predicate: #Predicate { history in
                history.container?.id == containerId
                    && history.lastAccessedAt >= cutoff
                    && (matchAll
                        || history.urlString.localizedStandardContains(trimmed)
                        || history.title.localizedStandardContains(trimmed))
            },
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )
        descriptor.fetchOffset = offset
        // One row past the page answers "is there another page?" without a count query.
        descriptor.fetchLimit = limit + 1

        do {
            let rows = try modelContext.fetch(descriptor)
            return HistoryPage(items: Array(rows.prefix(limit)), hasMore: rows.count > limit)
        } catch {
            logger.error("Error paging history: \(String(describing: error), privacy: .public)")
            return .empty
        }
    }

    func delete(_ item: History) {
        modelContext.delete(item)
        try? modelContext.save()
    }

    /// Every visit in one space inside the range. `.all` clears the space, which is what
    /// `clearContainerHistory` does; this one exists so the panel can clear just today.
    @discardableResult
    func delete(range: HistoryRange, in containerId: UUID, now: Date = Date()) -> Int {
        let cutoff = range.cutoff(from: now) ?? .distantPast
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { $0.container?.id == containerId && $0.lastAccessedAt >= cutoff }
        )

        do {
            let rows = try modelContext.fetch(descriptor)
            for row in rows { modelContext.delete(row) }
            try modelContext.save()
            return rows.count
        } catch {
            logger.error("Error deleting history range: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    func clearContainerHistory(_ container: TabContainer) {
        let containerId = container.id
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { $0.container?.id == containerId }
        )

        do {
            let histories = try modelContext.fetch(descriptor)

            for history in histories {
                modelContext.delete(history)
            }

            try modelContext.save()
        } catch {
            logger.error("Failed to clear history for container \(container.id): \(error.localizedDescription)")
        }
    }
}
