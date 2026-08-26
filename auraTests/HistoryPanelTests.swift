@testable import Aura
import Foundation
import SwiftData
import Testing

/// The sidebar history panel's data layer: offset paging, date grouping, the time-range
/// filter and the two deletes. No views here; the panel is a thin shell over these.
@MainActor
struct HistoryPanelTests {
    private func makeManager() throws -> (HistoryManager, TabContainer) {
        let modelContainer = try ModelContainer(
            for: TabContainer.self, History.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(modelContainer)
        let space = TabContainer(name: "History Space")
        context.insert(space)
        try context.save()
        let manager = HistoryManager(modelContainer: modelContainer, modelContext: context)
        return (manager, space)
    }

    @discardableResult
    private func record(
        _ manager: HistoryManager,
        in space: TabContainer,
        index: Int,
        at date: Date,
        title: String? = nil
    ) throws -> History {
        let url = try #require(URL(string: "https://example.com/page-\(index)"))
        let entry = History(
            url: url,
            title: title ?? "Page \(index)",
            faviconURL: url,
            createdAt: date,
            lastAccessedAt: date,
            visitCount: 1,
            container: space
        )
        manager.modelContext.insert(entry)
        space.history.append(entry)
        try manager.modelContext.save()
        return entry
    }

    // MARK: - Paging

    @Test func pagingWalksTheWholeTableAndReportsWhenItIsDone() throws {
        let (manager, space) = try makeManager()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Newest first once sorted: index 0 is the most recent.
        for index in 0 ..< 120 {
            try record(manager, in: space, index: index, at: base.addingTimeInterval(-Double(index)))
        }

        let first = manager.page(in: space.id, offset: 0, limit: 50)
        #expect(first.items.count == 50)
        #expect(first.hasMore)
        #expect(first.items.first?.title == "Page 0")

        let last = manager.page(in: space.id, offset: 100, limit: 50)
        #expect(last.items.count == 20)
        #expect(last.hasMore == false)
        #expect(last.items.first?.title == "Page 100")

        // Pages must not overlap: 120 rows over three pages, every id distinct.
        let second = manager.page(in: space.id, offset: 50, limit: 50)
        let ids = Set((first.items + second.items + last.items).map(\.id))
        #expect(ids.count == 120)
    }

    @Test func pagingStaysInsideOneSpace() throws {
        let (manager, space) = try makeManager()
        let other = TabContainer(name: "Other Space")
        manager.modelContext.insert(other)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try record(manager, in: space, index: 1, at: base)
        try record(manager, in: other, index: 2, at: base)

        #expect(manager.page(in: space.id, offset: 0, limit: 10).items.count == 1)
        #expect(manager.page(in: other.id, offset: 0, limit: 10).items.count == 1)
    }

    @Test func searchAndRangeNarrowThePage() throws {
        let (manager, space) = try makeManager()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let earlierToday = calendar.startOfDay(for: now).addingTimeInterval(60)
        let lastYear = try #require(calendar.date(byAdding: .year, value: -1, to: now))

        try record(manager, in: space, index: 1, at: earlierToday, title: "Swift release notes")
        try record(manager, in: space, index: 2, at: earlierToday, title: "Cat pictures")
        try record(manager, in: space, index: 3, at: lastYear, title: "Swift 5 release notes")

        let matches = manager.page(matching: "swift", in: space.id, offset: 0, limit: 10, now: now)
        #expect(matches.items.count == 2)

        let today = manager.page(range: .today, in: space.id, offset: 0, limit: 10, now: now)
        #expect(today.items.count == 2)

        let both = manager.page(matching: "swift", range: .today, in: space.id, offset: 0, limit: 10, now: now)
        #expect(both.items.map(\.title) == ["Swift release notes"])
    }

    @Test func aZeroLengthPageAsksTheStoreForNothing() throws {
        let (manager, space) = try makeManager()
        try record(manager, in: space, index: 1, at: Date())
        #expect(manager.page(in: space.id, offset: 0, limit: 0).items.isEmpty)
        #expect(manager.page(in: space.id, offset: -1, limit: 10).items.isEmpty)
    }

    // MARK: - Deleting

    @Test func deletingOneEntryLeavesTheRestAlone() throws {
        let (manager, space) = try makeManager()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let doomed = try record(manager, in: space, index: 1, at: base)
        try record(manager, in: space, index: 2, at: base.addingTimeInterval(-10))

        manager.delete(doomed)

        let remaining = manager.page(in: space.id, offset: 0, limit: 10)
        #expect(remaining.items.map(\.title) == ["Page 2"])
    }

    @Test func deletingARangeSparesEverythingOlderThanIt() throws {
        let (manager, space) = try makeManager()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let earlierToday = calendar.startOfDay(for: now).addingTimeInterval(60)
        let lastYear = try #require(calendar.date(byAdding: .year, value: -1, to: now))

        try record(manager, in: space, index: 1, at: earlierToday)
        try record(manager, in: space, index: 2, at: lastYear)

        #expect(manager.delete(range: .today, in: space.id, now: now) == 1)
        let remaining = manager.page(in: space.id, offset: 0, limit: 10, now: now)
        #expect(remaining.items.map(\.title) == ["Page 2"])

        #expect(manager.delete(range: .all, in: space.id, now: now) == 1)
        #expect(manager.page(in: space.id, offset: 0, limit: 10, now: now).items.isEmpty)
    }

    // MARK: - Grouping

    @Test func sectionsRunNewestFirstAndSkipEmptyBuckets() throws {
        let (manager, space) = try makeManager()
        let calendar = Calendar.current
        // Mid-week and mid-month, so "yesterday" cannot fall into a previous week or month.
        let now = try #require(
            calendar.date(from: DateComponents(year: 2025, month: 6, day: 18, hour: 12))
        )
        let today = calendar.startOfDay(for: now).addingTimeInterval(3600)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let older = try #require(calendar.date(byAdding: .year, value: -2, to: today))

        let entries = try [
            record(manager, in: space, index: 1, at: today),
            record(manager, in: space, index: 2, at: yesterday),
            record(manager, in: space, index: 3, at: older)
        ]

        let sections = HistoryGrouping.sections(for: entries, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Older"])
        #expect(sections.allSatisfy { $0.items.count == 1 })
    }

    @Test func groupingKeepsTheOrderTheStoreReturned() throws {
        let (manager, space) = try makeManager()
        let calendar = Calendar.current
        let now = try #require(
            calendar.date(from: DateComponents(year: 2025, month: 6, day: 18, hour: 12))
        )
        let today = calendar.startOfDay(for: now).addingTimeInterval(3600)
        for index in 0 ..< 3 {
            try record(manager, in: space, index: index, at: today.addingTimeInterval(-Double(index)))
        }

        let page = manager.page(in: space.id, offset: 0, limit: 10, now: now)
        let sections = HistoryGrouping.sections(for: page.items, now: now, calendar: calendar)
        #expect(sections.count == 1)
        #expect(sections[0].items.map(\.title) == ["Page 0", "Page 1", "Page 2"])
    }

    @Test func emptyInputMakesNoSections() {
        #expect(HistoryGrouping.sections(for: []).isEmpty)
    }

    @Test func rangeCutoffsAreCalendarBoundariesNotRollingWindows() throws {
        let calendar = Calendar.current
        let now = try #require(
            calendar.date(from: DateComponents(year: 2025, month: 6, day: 18, hour: 2))
        )
        // 2am: a rolling 24-hour window would still include yesterday evening.
        let todayCutoff = try #require(HistoryRange.today.cutoff(from: now, calendar: calendar))
        #expect(todayCutoff == calendar.startOfDay(for: now))
        #expect(HistoryRange.all.cutoff(from: now, calendar: calendar) == nil)

        let monthCutoff = try #require(HistoryRange.month.cutoff(from: now, calendar: calendar))
        #expect(calendar.component(.day, from: monthCutoff) == 1)
    }

    // MARK: - Recording

    /// The page script reports on every `<title>` mutation. Two reports for the same URL
    /// are one visit, with the newer title winning.
    @Test func titleOnlyChangeDoesNotCountAsASecondVisit() throws {
        let (manager, space) = try makeManager()
        let url = try #require(URL(string: "https://example.com/live"))
        var gate = HistoryVisitGate()

        for title in ["Loading", "Loaded (3 new)"] {
            manager.record(
                title: title,
                url: url,
                container: space,
                countsAsVisit: gate.countsAsVisit(url)
            )
        }

        let rows = manager.recent(limit: 10, in: space.id)
        #expect(rows.count == 1)
        #expect(rows.first?.visitCount == 1)
        #expect(rows.first?.title == "Loaded (3 new)")
    }

    /// A real navigation away and back is still two visits.
    @Test func navigatingAwayAndBackCountsTwoVisits() throws {
        let (manager, space) = try makeManager()
        let first = try #require(URL(string: "https://example.com/a"))
        let second = try #require(URL(string: "https://example.com/b"))
        var gate = HistoryVisitGate()

        for url in [first, second, first] {
            manager.record(title: "Page", url: url, container: space, countsAsVisit: gate.countsAsVisit(url))
        }

        let visits = Dictionary(
            uniqueKeysWithValues: manager.recent(limit: 10, in: space.id).map { ($0.urlString, $0.visitCount) }
        )
        #expect(visits[first.absoluteString] == 2)
        #expect(visits[second.absoluteString] == 1)
    }

    /// A repeat visit used to keep the row's first-ever title and favicon forever.
    @Test func repeatVisitRefreshesTitleAndFavicon() throws {
        let (manager, space) = try makeManager()
        let url = try #require(URL(string: "https://example.com/renamed"))
        let icon = try #require(URL(string: "https://example.com/favicon.ico"))

        manager.record(title: "Old title", url: url, container: space)
        manager.record(title: "New title", url: url, faviconURL: icon, container: space)

        let row = try #require(manager.recent(limit: 10, in: space.id).first)
        #expect(row.visitCount == 2)
        #expect(row.title == "New title")
        #expect(row.faviconURL == icon)

        // An empty title from a page that has not set one yet must not blank the row.
        manager.record(title: "", url: url, container: space)
        #expect(try #require(manager.recent(limit: 10, in: space.id).first).title == "New title")
    }

    /// The page URL is not a favicon. Storing it made every reader fetch the HTML as an image.
    @Test func visitWithNoFaviconStoresNil() throws {
        let (manager, space) = try makeManager()
        let url = try #require(URL(string: "https://example.com/no-icon"))

        manager.record(title: "No icon", url: url, container: space)

        #expect(manager.recent(limit: 10, in: space.id).first?.faviconURL == nil)
    }
}

@Suite("History visit gate")
struct HistoryVisitGateTests {
    @Test("A title tick with nothing new is no work at all")
    func titleTickWithNoChangeIsSkipped() {
        var gate = HistoryVisitGate()
        let url = URL(string: "https://mail.example.com/inbox")!
        #expect(gate.change(url: url, title: "Inbox", favicon: nil) == .visit)
        #expect(gate.change(url: url, title: "Inbox", favicon: nil) == .none)
        #expect(gate.change(url: url, title: "(1) Inbox", favicon: nil) == .details)
        #expect(gate.change(url: url, title: "(1) Inbox", favicon: nil) == .none)
        #expect(gate.change(url: URL(string: "https://example.com")!, title: "(1) Inbox", favicon: nil) == .visit)
    }
}
