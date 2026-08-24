import SwiftData
import SwiftUI
import WebKit

// MARK: - Tab Searching Providing

protocol TabSearchingProviding {
    func search(
        _ text: String,
        activeContainer: TabContainer?,
        modelContext: ModelContext
    ) -> [Tab]
}

// MARK: - Tab Searching Service

final class TabSearchingService: TabSearchingProviding {
    func search(
        _ text: String,
        activeContainer: TabContainer? = nil,
        modelContext: ModelContext
    ) -> [Tab] {
        let activeContainerId = activeContainer?.id ?? UUID()
        let trimmedText = text.trimmingCharacters(in: .whitespaces)

        let predicate: Predicate<Tab>
        if trimmedText.isEmpty {
            predicate = #Predicate { _ in true }
        } else {
            predicate = #Predicate { tab in
                (
                    tab.urlString.localizedStandardContains(trimmedText) ||
                        tab.title
                        .localizedStandardContains(
                            trimmedText
                        )
                ) && tab.container.id == activeContainerId
            }
        }

        let descriptor = FetchDescriptor<Tab>(predicate: predicate)

        do {
            let results = try modelContext.fetch(descriptor)
            let now = Date()

            // Score once per tab: recomputing inside the comparator ran the scorer
            // O(n log n) times per launcher keystroke.
            return results
                .map { (tab: $0, score: combinedScore(for: $0, query: trimmedText, now: now)) }
                .sorted { $0.score > $1.score }
                .map(\.tab)

        } catch {
            return []
        }
    }

    private func combinedScore(for tab: Tab, query: String, now: Date) -> Double {
        let match = scoreMatch(tab, text: query)

        let timeInterval: TimeInterval = if let accessedAt = tab.lastAccessedAt {
            now.timeIntervalSince(accessedAt)
        } else {
            1_000_000 // far in the past → lowest recency
        }

        let recencyBoost = max(0, 1_000_000 - timeInterval)
        return Double(match * 1000) + recencyBoost
    }

    private func scoreMatch(_ tab: Tab, text: String) -> Int {
        let text = text.lowercased()
        let title = tab.title.lowercased()
        let url = tab.urlString.lowercased()

        func score(_ field: String) -> Int {
            if field == text { return 100 }
            if field.hasPrefix(text) { return 90 }
            if field.contains(text) { return 75 }
            if text.contains(field) { return 50 }
            return 0
        }

        return max(score(title), score(url))
    }
}
