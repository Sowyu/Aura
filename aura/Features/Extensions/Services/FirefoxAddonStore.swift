import Foundation

/// The add-on kinds AMO serves. Raw values are the API's `type=` values.
enum FirefoxAddonType: String, CaseIterable, Identifiable {
    case `extension`
    case statictheme
    case dictionary
    case language

    var id: String { rawValue }

    /// Filter-chip label.
    var pluralTitle: String {
        switch self {
        case .extension: return "Extensions"
        case .statictheme: return "Themes"
        case .dictionary: return "Dictionaries"
        case .language: return "Language packs"
        }
    }
}

/// The AMO `sort=` values the store exposes.
enum FirefoxAddonSort: String, CaseIterable, Identifiable {
    case relevance
    case users
    case rating
    case updated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .users: return "Users"
        case .rating: return "Rating"
        case .updated: return "Recently updated"
        }
    }
}

/// One add-on listing from addons.mozilla.org.
struct FirefoxAddon: Identifiable, Equatable {
    let id: Int
    let slug: String
    let name: String
    /// The add-on's WebExtension id, the only field that survives a rename or a
    /// locale-translated name. Nil on payloads that predate it.
    var guid: String?
    var summary: String?
    var version: String?
    var iconURL: URL?
    var downloadURL: URL?
    var dailyUsers: Int = 0
    var authors: [String] = []
    var averageRating: Double = 0
    var type: FirefoxAddonType = .extension
    var permissions: [String] = []
    var optionalPermissions: [String] = []
    var hostPermissions: [String] = []
    var lastUpdated: Date?

    var authorLine: String? {
        authors.isEmpty ? nil : authors.joined(separator: ", ")
    }

    /// Everything the add-on can ever ask for, which is what compatibility is judged on.
    /// Permissions the add-on cannot run without. Optional ones are requested at use time
    /// and a missing optional API degrades one feature, not the add-on, so they don't count.
    var requestedPermissions: [String] {
        permissions + hostPermissions
    }
}

/// One page of search results plus whether AMO has another one.
struct FirefoxAddonPage: Equatable {
    var addons: [FirefoxAddon] = []
    var hasMore = false
}

enum FirefoxAddonStoreError: LocalizedError {
    case addonNotFound
    case missingDownload
    case unpackFailed(String)

    var errorDescription: String? {
        switch self {
        case .addonNotFound:
            return "Couldn't find that add-on on addons.mozilla.org."
        case .missingDownload:
            return "This add-on has no downloadable file."
        case let .unpackFailed(reason):
            return "Couldn't unpack the add-on: \(reason)"
        }
    }
}

/// Client for addons.mozilla.org (AMO). Firefox extensions are standard
/// WebExtensions packaged as .xpi (a zip), so anything downloaded here goes
/// through the same unpacked-folder install path as a local extension.
///
/// The bundled blocker is not served from here. uBlock Origin Lite ships as its
/// GitHub release build, `uBOLiteRedux@raymondhill.net`, and Aura knows no AMO
/// slug for it, so nothing in the store offers that id an update. It is replaced
/// by shipping a newer archive in `BundledExtensions`.
struct FirefoxAddonStore {
    static let shared = FirefoxAddonStore()

    static let pageSize = 20

    private let apiBase = URL(string: "https://addons.mozilla.org/api/v5/addons/")!

    /// Extracts the slug from an AMO listing URL like
    /// https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/
    static func slug(fromPageURL text: String) -> String? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, host.hasSuffix("addons.mozilla.org")
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let addonIndex = parts.firstIndex(of: "addon"), addonIndex + 1 < parts.count else { return nil }
        return parts[addonIndex + 1]
    }

    /// The one-argument form the rest of the app was built on: popular extensions only.
    func search(_ query: String) async throws -> [FirefoxAddon] {
        try await search(query, type: .extension, sort: .users, page: 1, pageSize: 10).addons
    }

    /// `type: nil` searches every add-on kind.
    func search(
        _ query: String,
        type: FirefoxAddonType?,
        sort: FirefoxAddonSort,
        page: Int,
        pageSize: Int = FirefoxAddonStore.pageSize
    ) async throws -> FirefoxAddonPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Relevance has nothing to rank against without a query, and AMO rejects it.
        let effectiveSort: FirefoxAddonSort = (trimmed.isEmpty && sort == .relevance) ? .users : sort

        var items = [
            URLQueryItem(name: "app", value: "firefox"),
            URLQueryItem(name: "sort", value: effectiveSort.rawValue),
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "page_size", value: String(pageSize))
        ]
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
        if let type { items.append(URLQueryItem(name: "type", value: type.rawValue)) }

        var components = URLComponents(
            url: apiBase.appendingPathComponent("search/"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = items
        guard let searchURL = components?.url else { return FirefoxAddonPage() }
        let (data, _) = try await URLSession.shared.data(from: searchURL)
        return Self.parsePage(data)
    }

    /// The same endpoint answers to a gecko id, which is what an installed add-on
    /// knows itself by and the only handle an update check has.
    func addon(guid: String) async throws -> FirefoxAddon {
        try await addon(slug: guid)
    }

    func addon(slug: String) async throws -> FirefoxAddon {
        let url = apiBase.appendingPathComponent("addon/\(slug)/")
        // A launch-time update check must not sit on a stalled connection for the
        // default minute; AMO either answers quickly or is treated as unreachable.
        let request = URLRequest(url: url, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode != 404 else {
            throw FirefoxAddonStoreError.addonNotFound
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addon = Self.parseAddon(json)
        else {
            throw FirefoxAddonStoreError.addonNotFound
        }
        return addon
    }

    /// Downloads the .xpi to a temporary file and returns its URL.
    func downloadXPI(from url: URL) async throws -> URL {
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-addon-\(UUID().uuidString).xpi")
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    // MARK: - Response parsing

    /// Internal so a fixture payload can be decoded without touching the network.
    static func parsePage(_ data: Data) -> FirefoxAddonPage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return FirefoxAddonPage()
        }
        let results = json["results"] as? [[String: Any]] ?? []
        return FirefoxAddonPage(addons: results.compactMap(parseAddon), hasMore: json["next"] is String)
    }

    private static func parseAddon(_ json: [String: Any]) -> FirefoxAddon? {
        guard let id = json["id"] as? Int,
              let slug = json["slug"] as? String,
              let name = localizedString(json["name"])
        else { return nil }

        let currentVersion = json["current_version"] as? [String: Any]
        // API v5 uses a single "file" object; older shapes used a "files" array.
        let file = currentVersion?["file"] as? [String: Any]
            ?? (currentVersion?["files"] as? [[String: Any]])?.first
        let ratings = json["ratings"] as? [String: Any]

        return FirefoxAddon(
            id: id,
            slug: slug,
            name: name,
            guid: json["guid"] as? String,
            summary: localizedString(json["summary"]),
            version: currentVersion?["version"] as? String,
            iconURL: (json["icon_url"] as? String).flatMap(URL.init(string:)),
            downloadURL: (file?["url"] as? String).flatMap(URL.init(string:)),
            dailyUsers: json["average_daily_users"] as? Int ?? 0,
            authors: (json["authors"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [],
            averageRating: (ratings?["average"] as? NSNumber)?.doubleValue ?? 0,
            type: (json["type"] as? String).flatMap(FirefoxAddonType.init(rawValue:)) ?? .extension,
            permissions: file?["permissions"] as? [String] ?? [],
            optionalPermissions: file?["optional_permissions"] as? [String] ?? [],
            hostPermissions: file?["host_permissions"] as? [String] ?? [],
            lastUpdated: (json["last_updated"] as? String).flatMap(parseDate)
        )
    }

    /// AMO stamps are ISO-8601, sometimes with fractional seconds and no zone suffix.
    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        return formatter.date(from: text + "Z")
    }

    /// AMO localizes text fields as {"en-US": "..."} maps; some endpoints
    /// return plain strings. Accept both.
    private static func localizedString(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        guard let map = value as? [String: Any] else { return nil }
        let preferred = Locale.preferredLanguages.first ?? "en-US"
        return (map[preferred] ?? map["en-US"] ?? map.values.first) as? String
    }
}

/// Unpacks .xpi archives (plain zips) using the system's ditto.
enum XPIUnpacker {
    static func unpack(_ archiveURL: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw FirefoxAddonStoreError.unpackFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let reason = String(data: stderrData, encoding: .utf8) ?? "ditto exited \(process.terminationStatus)"
            throw FirefoxAddonStoreError.unpackFailed(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The directory holding manifest.json — the archive root, or a single
    /// nested folder (some archives wrap their content in one).
    static func manifestRoot(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
            return directory
        }
        let children = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if fileManager.fileExists(atPath: child.appendingPathComponent("manifest.json").path) {
                return child
            }
        }
        return nil
    }

    /// A .crx is a zip behind a signature header. Strips the header and writes the plain
    /// zip to a temporary file. The signature is not checked: a file the user picked by
    /// hand is trusted the same way an unpacked folder is.
    static func zipFromCRX(_ archiveURL: URL) throws -> URL {
        let data = try Data(contentsOf: archiveURL)
        let payload = try crxPayload(data)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-crx-\(UUID().uuidString).zip")
        try payload.write(to: destination)
        return destination
    }

    /// CRX3: "Cr24", version 3, header length, header, zip. CRX2 instead stores a public
    /// key length and a signature length before its two blobs.
    static func crxPayload(_ data: Data) throws -> Data {
        guard data.count > 16, Array(data.prefix(4)) == Array("Cr24".utf8) else {
            throw FirefoxAddonStoreError.unpackFailed("Not a Chrome extension archive (no Cr24 header).")
        }
        let offset: Int
        switch littleEndian(data, at: 4) {
        case 3:
            offset = 12 + Int(littleEndian(data, at: 8))
        case 2:
            offset = 16 + Int(littleEndian(data, at: 8)) + Int(littleEndian(data, at: 12))
        case let version:
            throw FirefoxAddonStoreError.unpackFailed("Unsupported CRX version \(version).")
        }
        guard offset > 0, offset < data.count else {
            throw FirefoxAddonStoreError.unpackFailed("CRX header runs past the end of the file.")
        }
        return data.subdata(in: offset ..< data.count)
    }

    private static func littleEndian(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in (0 ..< 4).reversed() {
            value = (value << 8) | UInt32(data[data.startIndex + offset + index])
        }
        return value
    }
}
