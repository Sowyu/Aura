import Foundation

/// One add-on listing from addons.mozilla.org.
struct FirefoxAddon: Identifiable, Equatable {
    let id: Int
    let slug: String
    let name: String
    let summary: String?
    let version: String?
    let iconURL: URL?
    let downloadURL: URL?
    let dailyUsers: Int
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
struct FirefoxAddonStore {
    static let shared = FirefoxAddonStore()

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

    func search(_ query: String) async throws -> [FirefoxAddon] {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("search/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "app", value: "firefox"),
            URLQueryItem(name: "type", value: "extension"),
            URLQueryItem(name: "sort", value: "users"),
            URLQueryItem(name: "page_size", value: "10")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return [] }
        return results.compactMap(Self.parseAddon)
    }

    func addon(slug: String) async throws -> FirefoxAddon {
        let url = apiBase.appendingPathComponent("addon/\(slug)/")
        let (data, response) = try await URLSession.shared.data(from: url)
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

    private static func parseAddon(_ json: [String: Any]) -> FirefoxAddon? {
        guard let id = json["id"] as? Int,
              let slug = json["slug"] as? String,
              let name = localizedString(json["name"])
        else { return nil }

        let currentVersion = json["current_version"] as? [String: Any]
        // API v5 uses a single "file" object; older shapes used a "files" array.
        let file = currentVersion?["file"] as? [String: Any]
            ?? (currentVersion?["files"] as? [[String: Any]])?.first

        return FirefoxAddon(
            id: id,
            slug: slug,
            name: name,
            summary: localizedString(json["summary"]),
            version: currentVersion?["version"] as? String,
            iconURL: (json["icon_url"] as? String).flatMap(URL.init(string:)),
            downloadURL: (file?["url"] as? String).flatMap(URL.init(string:)),
            dailyUsers: json["average_daily_users"] as? Int ?? 0
        )
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
}
