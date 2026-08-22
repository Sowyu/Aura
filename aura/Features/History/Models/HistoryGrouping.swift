import Foundation

/// Date buckets for the history panel.
///
/// Ported from Nook's `groupHistoryEntries` (`Nook/Components/Sidebar/Menu/
/// SidebarMenuHistoryTab.swift`) by Maciek Bagiński, GPL-3.0. The nested date-component
/// arithmetic is replaced by the ordered-bucket table Aura's downloads panel already
/// uses, so the two panels group and order the same way.
enum HistoryGrouping {
    struct Section: Identifiable {
        let id: String
        let items: [History]

        var title: String {
            id
        }
    }

    /// Ordered newest bucket first. A visit lands in the first bucket whose lower bound
    /// it clears, so the table doubles as the display order.
    static func buckets(now: Date, calendar: Calendar = .current) -> [(label: String, start: Date)] {
        let startOfToday = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let thisWeek = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        ) ?? startOfToday
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? thisWeek
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth

        return [
            ("Today", startOfToday),
            ("Yesterday", yesterday),
            ("This Week", thisWeek),
            ("Last Week", lastWeek),
            ("This Month", thisMonth),
            ("Last Month", lastMonth),
            ("Older", .distantPast)
        ]
    }

    /// Empty buckets are dropped. Items keep the order they arrive in, which is the
    /// store's `lastAccessedAt` descending, so no second sort is needed.
    static func sections(
        for items: [History],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Section] {
        guard !items.isEmpty else { return [] }
        let table = buckets(now: now, calendar: calendar)

        var grouped: [String: [History]] = [:]
        for item in items {
            let label = table.first { item.lastAccessedAt >= $0.start }?.label ?? "Older"
            grouped[label, default: []].append(item)
        }

        return table.compactMap { label, _ in
            guard let bucket = grouped[label], !bucket.isEmpty else { return nil }
            return Section(id: label, items: bucket)
        }
    }
}
