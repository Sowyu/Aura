@testable import Aura
import Foundation
import Testing

/// A translated add-on names itself `__MSG_extName__` and keeps the real string in
/// `_locales`. Before this resolved, the browser showed the folder id in the row, the
/// consent sheet and the duplicate check.
struct ExtensionLocalizationTests {
    /// Writes a manifest plus locale files and hands back the folder.
    private func makeExtension(
        name: String,
        description: String? = nil,
        shortName: String? = nil,
        defaultLocale: String? = "en",
        locales: [String: [String: String]] = ["en": ["extName": "Aura Test Extension"]]
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-i18n-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var manifest: [String: Any] = ["manifest_version": 3, "name": name, "version": "1.0"]
        manifest["default_locale"] = defaultLocale
        manifest["description"] = description
        manifest["short_name"] = shortName
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("manifest.json"))

        for (locale, messages) in locales {
            let folder = directory
                .appendingPathComponent("_locales", isDirectory: true)
                .appendingPathComponent(locale, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let payload = messages.mapValues { ["message": $0] }
            try JSONSerialization.data(withJSONObject: payload)
                .write(to: folder.appendingPathComponent("messages.json"))
        }
        return directory
    }

    // MARK: - Substitution

    @Test func placeholdersResolveAgainstTheMessagesFile() {
        let messages = ["extname": "uBlock Origin", "suffix": "Lite"]
        #expect(ExtensionLocalization.resolve("__MSG_extName__", messages: messages) == "uBlock Origin")
        // Case-insensitive keys, and a placeholder anywhere in the string.
        #expect(
            ExtensionLocalization.resolve("__MSG_EXTNAME__ __MSG_suffix__", messages: messages)
                == "uBlock Origin Lite"
        )
        #expect(ExtensionLocalization.resolve("Plain name", messages: messages) == "Plain name")
    }

    /// Half a substitution is worse than none: a row reading "__MSG_extName__ for Aura"
    /// is what the caller falls back from.
    @Test func anUnknownKeyResolvesToNothing() {
        #expect(ExtensionLocalization.resolve("__MSG_missing__", messages: ["extname": "x"]) == nil)
        #expect(ExtensionLocalization.resolve("__MSG_extName__ x", messages: [:]) == nil)
        // Chrome's predefined placeholders have no message either, so they read as
        // unresolvable rather than being passed through raw.
        #expect(ExtensionLocalization.resolve("__MSG_@@extension_id__", messages: [:]) == nil)
        // An unterminated placeholder is a broken manifest, not a name.
        #expect(ExtensionLocalization.resolve("__MSG_extName", messages: ["extname": "x"]) == nil)
    }

    @Test func localeCandidatesPreferTheUserThenTheAddOnsDefault() {
        let candidates = ExtensionLocalization.candidateLocales(preferred: ["de-DE", "en"], defaultLocale: "en-US")
        #expect(candidates == ["de_DE", "de", "en", "en_US"])
        // No preferred languages at all still leaves the manifest's own default.
        #expect(ExtensionLocalization.candidateLocales(preferred: [], defaultLocale: "fr") == ["fr"])
        #expect(ExtensionLocalization.candidateLocales(preferred: ["en"], defaultLocale: nil) == ["en"])
    }

    // MARK: - Against a folder

    @Test func aTranslatedManifestShowsTheUsersLanguage() throws {
        let directory = try makeExtension(
            name: "__MSG_extName__",
            description: "__MSG_extDescription__",
            locales: [
                "en": ["extName": "Test Extension", "extDescription": "Blocks things"],
                "de": ["extName": "Testerweiterung", "extDescription": "Blockiert Dinge"]
            ]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let german = ExtensionLocalization.localized(
            "__MSG_extName__", in: directory, defaultLocale: "en", preferred: ["de-DE"]
        )
        #expect(german == "Testerweiterung", "the region form falls back to the bare language folder")

        // A language the add-on does not ship falls through to its own default locale.
        let fallback = ExtensionLocalization.localized(
            "__MSG_extDescription__", in: directory, defaultLocale: "en", preferred: ["ja"]
        )
        #expect(fallback == "Blocks things")
    }

    /// The scan is what the row, the consent sheet and duplicate detection all read.
    @Test func theScanResolvesNameAndDescription() async throws {
        let directory = try makeExtension(
            name: "__MSG_extName__",
            description: "__MSG_extDescription__",
            locales: ["en": ["extName": "Resolved Name", "extDescription": "Resolved description"]]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let scanned = await Task.detached {
            ExtensionManager.prepare(at: directory, patchesShim: false)
        }.value
        #expect(scanned.displayName == "Resolved Name")
        #expect(scanned.displayDescription == "Resolved description")
    }

    /// An add-on whose name cannot be resolved still has `short_name` before the row
    /// gives up and shows the folder id.
    @Test func shortNameIsTheLastRealNameBeforeTheFolderID() async throws {
        let directory = try makeExtension(
            name: "__MSG_missingKey__",
            shortName: "Fallback Name",
            locales: ["en": ["extName": "Never used"]]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let scanned = await Task.detached {
            ExtensionManager.prepare(at: directory, patchesShim: false)
        }.value
        #expect(scanned.displayName == "Fallback Name")
    }

    /// No `_locales` at all is the common case, and it must cost nothing and change
    /// nothing.
    @Test func anUntranslatedManifestIsUntouched() async throws {
        let directory = try makeExtension(
            name: "Plain Extension", description: "Plain description", defaultLocale: nil, locales: [:]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let scanned = await Task.detached {
            ExtensionManager.prepare(at: directory, patchesShim: false)
        }.value
        #expect(scanned.displayName == "Plain Extension")
        #expect(scanned.displayDescription == "Plain description")
    }
}
