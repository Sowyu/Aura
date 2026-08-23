import Foundation
import SwiftData

/// The file tray: every local file Aura has opened, newest first.
///
/// One store for the whole app rather than one per window, because a file is not a
/// window's property: opening it in a second window moves the same row rather than
/// making another. The lazily resolved context matches `SiteSpaceRuleService`, which is
/// the other table read from places that have no window to take a context from.
///
/// Private windows never reach here. A file opened in one is browsing the user asked not
/// to be remembered, and a tray row is exactly the record they said no to.
@Observable
@MainActor
final class OpenedFileStore {
    static let shared = OpenedFileStore()

    /// How many unpinned rows survive a sweep. Deep enough to cover a working week of
    /// documents, shallow enough that the list is still readable without a search field.
    static let unpinnedLimit = 40

    /// Newest first, which is the order the tray draws.
    private(set) var files: [OpenedFile] = []

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var didPruneGrants = false

    init(context: ModelContext? = nil) {
        self.context = context
        if context != nil { reload() }
    }

    // MARK: - Reading

    /// Loads on first use rather than in `init`, so a window opening does not pay for a
    /// tray nobody has looked at yet.
    ///
    /// Called from `task`, never from a view body: `reload` writes an observed property,
    /// and writing one while SwiftUI is evaluating a body is what makes a view update
    /// itself in a loop.
    func loadIfNeeded() {
        if !didLoad { reload() }
    }

    private func loaded() -> [OpenedFile] {
        loadIfNeeded()
        return files
    }

    /// Safe to read from a view body: no load, no write, just what is in memory.
    var entries: [OpenedFile] { files }

    func entry(for url: URL) -> OpenedFile? {
        let path = url.standardizedFileURL.path
        return loaded().first { $0.path == path }
    }

    // MARK: - Writing

    /// Records a file as opened, in `tabID` when a tab is showing it.
    ///
    /// Opening the same file again moves the existing row to the top instead of adding a
    /// second one: the path is the row's identity, the way a page's URL is a bookmark's.
    @discardableResult
    func record(_ url: URL, tabID: UUID? = nil, openedAt: Date = Date()) -> OpenedFile? {
        guard url.isFileURL, let context = resolvedContext() else { return nil }
        _ = loaded()
        let standardized = url.standardizedFileURL

        if let existing = entry(for: standardized) {
            existing.openedAt = openedAt
            existing.tabID = tabID ?? existing.tabID
            existing.locationString = standardized.absoluteString
            existing.displayName = standardized.lastPathComponent
            saveOrLog(context)
            reload()
            return existing
        }

        let file = OpenedFile.make(for: standardized, tabID: tabID, openedAt: openedAt)
        context.insert(file)
        saveOrLog(context)
        sweep(context)
        reload()
        pruneGrantsOnce()
        return file
    }

    /// The tab showing a file has gone. An unpinned row goes with it, which is what keeps
    /// the tray a list of what is open plus what was kept, rather than a second history.
    func tabClosed(_ tabID: UUID) {
        guard let context = resolvedContext() else { return }
        let matching = loaded().filter { $0.tabID == tabID }
        guard !matching.isEmpty else { return }
        for file in matching {
            if file.isPinned {
                file.tabID = nil
            } else {
                context.delete(file)
            }
        }
        saveOrLog(context)
        reload()
    }

    func setPinned(_ file: OpenedFile, _ isPinned: Bool) {
        guard let context = resolvedContext() else { return }
        file.isPinned = isPinned
        saveOrLog(context)
        reload()
    }

    func remove(_ file: OpenedFile) {
        guard let context = resolvedContext() else { return }
        FileAccessStore.shared.forget(file.url)
        context.delete(file)
        saveOrLog(context)
        reload()
    }

    func clearUnpinned() {
        guard let context = resolvedContext() else { return }
        for file in loaded() where !file.isPinned {
            FileAccessStore.shared.forget(file.url)
            context.delete(file)
        }
        saveOrLog(context)
        reload()
    }

    // MARK: - Internals

    /// Drops the oldest unpinned rows past the limit, and the grants that went with them:
    /// a bookmark for a file no row can reach is a permission nobody can see or revoke.
    private func sweep(_ context: ModelContext) {
        let all = fetchAll()
        let unpinned = all.filter { !$0.isPinned }
        guard unpinned.count > Self.unpinnedLimit else { return }
        for file in unpinned.dropFirst(Self.unpinnedLimit) {
            FileAccessStore.shared.forget(file.url)
            context.delete(file)
        }
        saveOrLog(context)
    }

    private func fetchAll() -> [OpenedFile] {
        guard let context = resolvedContext() else { return [] }
        let descriptor = FetchDescriptor<OpenedFile>(sortBy: [SortDescriptor(\.openedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func reload() {
        didLoad = true
        // Pinned rows first, then by how recently the file was opened. A pin is the
        // user saying "keep this where I can find it", so it stops sinking.
        files = fetchAll().sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.openedAt > rhs.openedAt
        }
    }

    /// Once per launch, after the tray is settled: a grant no row can reach is a
    /// permission the user can neither see nor revoke, which is what a file opened in a
    /// private window or a row removed by an older build leaves behind.
    private func pruneGrantsOnce() {
        guard !didPruneGrants else { return }
        didPruneGrants = true
        FileAccessStore.shared.prune(keeping: Set(files.map(\.path)))
    }

    private func resolvedContext() -> ModelContext? {
        if let context { return context }
        guard let container = try? ModelConfiguration.createOraContainer() else { return nil }
        let created = ModelContext(container)
        context = created
        return created
    }
}
