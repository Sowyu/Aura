import Foundation
import os.log
import SwiftData

private let logger = Logger(subsystem: "com.aurabrowser.app", category: "HistoryManager")

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
