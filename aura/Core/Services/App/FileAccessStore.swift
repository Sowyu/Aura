import AppKit
import Foundation
import OSLog

/// Security-scoped access to the local files Aura has been asked to open, one bookmark
/// per file.
///
/// Two things need it. A file opened yesterday is still in the tray today, and the
/// sandbox grant that came with the open panel died with the process, so a stored
/// bookmark is the only way back into it. And a path typed into the address field never
/// carried a grant at all: inside the sandbox only Powerbox hands one out, which is why
/// consent for a typed path ends in an open panel pointed at that file rather than in a
/// dialog on its own. A dialog can ask; it cannot grant.
///
/// The shape follows `SecurityScopedFolder` and `downloadFolderBookmark` in
/// `SettingsStore`: resolve once, start access once, keep it. `makeBookmark` and `start`
/// are injectable for the same reason they are there, so the behaviour can be exercised
/// without a sandbox.
@MainActor
final class FileAccessStore {
    static let shared = FileAccessStore()

    static let bookmarksKey = "files.accessBookmarks"

    private let defaults: UserDefaults
    private let makeBookmark: (URL) -> Data?
    private let resolveBookmark: (Data) -> (url: URL, isStale: Bool)?
    private let start: (URL) -> Bool

    /// File path to bookmark. Small enough to write whole on every change: one blob of a
    /// few hundred bytes per file the user has ever opened, and the tray prunes it.
    private(set) var bookmarks: [String: Data]

    /// Files whose access is open, by path.
    /// ponytail: access is started once per file and released when the process ends. Add
    /// an LRU release if a single session ever opens hundreds of files.
    private var opened: [String: URL] = [:]

    private let log = Logger(subsystem: "com.aurabrowser.app", category: "FileAccess")

    init(
        defaults: UserDefaults = .standard,
        makeBookmark: @escaping (URL) -> Data? = { url in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolveBookmark: @escaping (Data) -> (url: URL, isStale: Bool)? = { data in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            return (url, isStale)
        },
        start: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    ) {
        self.defaults = defaults
        self.makeBookmark = makeBookmark
        self.resolveBookmark = resolveBookmark
        self.start = start
        bookmarks = (defaults.dictionary(forKey: Self.bookmarksKey) as? [String: Data]) ?? [:]
    }

    /// Whether the process is inside the app sandbox. Outside it every readable path is
    /// readable and none of the bookmarking matters, which is the case unit tests and
    /// unsigned local builds run in.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: - Grants

    /// Writes down the grant that came with an open panel, a drop or a Finder open, so
    /// the same file can be reopened from the tray after a relaunch.
    func remember(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        guard let data = makeBookmark(url) else {
            log.debug("no bookmark for \(path, privacy: .public)")
            return
        }
        bookmarks[path] = data
        persist()
        opened[path] = url
    }

    /// Opens the stored grant for `url`, if there is one, and reports whether the file
    /// can be read now. Cheap to call repeatedly: a file already open is a dictionary hit.
    @discardableResult
    func beginAccess(to url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        if opened[path] != nil { return true }
        guard let data = bookmarks[path], let resolved = resolveBookmark(data) else { return false }
        guard start(resolved.url) else { return false }
        opened[path] = resolved.url
        // A stale bookmark still resolved, so this is the moment to write a fresh one.
        if resolved.isStale, let refreshed = makeBookmark(resolved.url) {
            bookmarks[path] = refreshed
            persist()
        }
        return true
    }

    /// Whether opening `url` has to ask the user first.
    ///
    /// Answered by trying the stored grant and then asking the file system, so anything
    /// the sandbox already allows (the Downloads folder, an unsandboxed build) needs no
    /// prompt. A file the sandbox hides is indistinguishable from one that is not there,
    /// so both end in the panel, where a missing file simply cannot be chosen.
    func needsConsent(for url: URL) -> Bool {
        guard url.isFileURL else { return false }
        beginAccess(to: url)
        return !FileManager.default.isReadableFile(atPath: url.standardizedFileURL.path)
    }

    func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard bookmarks.removeValue(forKey: path) != nil else { return }
        opened[path] = nil
        persist()
    }

    /// Drops bookmarks whose file is gone. Run when the tray is pruned, so a bookmark
    /// never outlives the row that is the only way to reach it.
    func prune(keeping keptPaths: Set<String>) {
        let stale = bookmarks.keys.filter { path in
            guard keptPaths.contains(path) else { return true }
            // Only a resolvable bookmark says the file is still there: inside the sandbox
            // `fileExists` on a path with no grant is false for a file that does exist.
            guard let data = bookmarks[path] else { return true }
            return resolveBookmark(data) == nil
        }
        guard !stale.isEmpty else { return }
        for path in stale {
            bookmarks[path] = nil
            opened[path] = nil
        }
        persist()
    }

    private func persist() {
        defaults.set(bookmarks, forKey: Self.bookmarksKey)
    }
}
