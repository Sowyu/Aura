import Foundation

/// HTML taken off a live page, held for the tab that is about to render it.
///
/// `aura://view-source` and `aura://reader` render natively, and a tab showing an
/// internal page has no web view at all, so the document has to be captured from the
/// original page *before* the new tab exists. Whoever opens the tab stores the markup
/// here first and the page tool reads it back by target address.
///
/// Nothing here persists: a tab restored after a relaunch finds an empty store and the
/// loader fetches the address again instead.
@MainActor
final class PageSourceStore {
    static let shared = PageSourceStore()

    private struct Entry {
        let html: String
        let stored: Date
    }

    /// Small on purpose. A page's markup runs to megabytes and only the last handful of
    /// captures can still be on screen.
    private static let limit = 6

    private var entries: [String: Entry] = [:]

    func store(_ html: String, for target: URL) {
        entries[target.absoluteString] = Entry(html: html, stored: Date())
        guard entries.count > Self.limit else { return }
        let oldest = entries.min { $0.value.stored < $1.value.stored }
        if let key = oldest?.key { entries.removeValue(forKey: key) }
    }

    func html(for target: URL) -> String? {
        entries[target.absoluteString]?.html
    }

    func clear() {
        entries.removeAll()
    }
}

/// Resolves the markup a page tool renders: the capture taken off the live page when
/// there is one, and a plain fetch when there is not.
enum PageSourceLoader {
    enum Failure: Error, Equatable {
        case notFetchable
        case emptyResponse
    }

    /// The capture, or nil when the address has to be fetched.
    @MainActor
    static func cached(_ target: URL) -> String? {
        PageSourceStore.shared.html(for: target)
    }

    /// Ephemeral, because this runs for a private tab whose capture the cache has
    /// evicted: `URLSession.shared` would put that page in the on-disk cache and any
    /// `Set-Cookie` in the process jar. Built once, because a session per fetch brings
    /// its own connection pool.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Fetches `target` and decodes it as text. Used only when the capture is gone, so
    /// this is the markup the server sends rather than the DOM the user was looking at;
    /// scripted pages come back close to empty and the view says so.
    ///
    /// No cookies ride along. The tab has no web view left to take a cookie store from
    /// at this point, and building a second one purely to read cookies would create a
    /// data store the space does not own.
    static func fetch(_ target: URL) async throws -> String {
        guard let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Failure.notFetchable
        }
        var request = URLRequest(url: target)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        guard !data.isEmpty else { throw Failure.emptyResponse }
        return decode(data)
    }

    /// The capture if there is one, the network if there is not. The one entry point the
    /// page tools use, so both resolve their markup the same way.
    @MainActor
    static func markup(for target: URL) async -> Swift.Result<String, Error> {
        if let cached = cached(target) { return .success(cached) }
        do {
            return .success(try await fetch(target))
        } catch {
            return .failure(error)
        }
    }

    /// UTF-8 first, then the two encodings old pages still ship in. `String(data:)`
    /// returns nil rather than replacement characters on a bad decode, so this cannot
    /// silently hand back mojibake for a Latin-1 page.
    static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        return String(decoding: data, as: UTF8.self)
    }
}
