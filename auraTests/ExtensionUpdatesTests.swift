@testable import Aura
import Foundation
import Testing

/// An installed add-on never updated before this: the version on disk was whatever the
/// user first downloaded. The check asks AMO by gecko id, so the fetch is injected here
/// and no test touches the network.
struct ExtensionUpdatesTests {
    private func installed(
        id: String,
        version: String?,
        geckoID: String?
    ) -> InstalledExtension {
        InstalledExtension(
            id: id,
            directoryURL: URL(fileURLWithPath: "/tmp/\(id)"),
            displayName: id,
            displayDescription: nil,
            displayVersion: version,
            geckoID: geckoID,
            isEnabled: true,
            icon: nil,
            loadError: nil
        )
    }

    private func addon(version: String?) -> FirefoxAddon {
        FirefoxAddon(id: 1, slug: "test", name: "Test", guid: "test@example.com", version: version)
    }

    // MARK: - Version comparison

    @Test func laterVersionsAreRecognisedNumerically() {
        // The one a string compare gets wrong.
        #expect(ExtensionVersion.isNewer("1.10.0", than: "1.9.0"))
        #expect(!ExtensionVersion.isNewer("1.9.0", than: "1.10.0"))
        #expect(ExtensionVersion.isNewer("2.0", than: "1.99.99"))
        // A longer version with the same prefix is a later build.
        #expect(ExtensionVersion.isNewer("1.0.1", than: "1.0"))
        #expect(!ExtensionVersion.isNewer("1.0", than: "1.0.1"))
        // uBlock Origin Lite's date-shaped versions.
        #expect(ExtensionVersion.isNewer("2026.820.1159", than: "2026.819.2300"))
    }

    /// Anything that is not clearly later must not offer an update: a row saying
    /// "Update to 1.0" for the 1.0 already installed is worse than no row.
    @Test func equalOrOlderVersionsAreNeverAnUpdate() {
        #expect(!ExtensionVersion.isNewer("1.2.3", than: "1.2.3"))
        #expect(!ExtensionVersion.isNewer("1.2", than: "1.2.0"))
        #expect(!ExtensionVersion.isNewer("", than: ""))
        #expect(!ExtensionVersion.isNewer("nonsense", than: "1.0"))
        // A suffix only breaks a numeric tie, so a beta sorts after the plain build.
        #expect(ExtensionVersion.isNewer("1.0b2", than: "1.0b1"))
        #expect(!ExtensionVersion.isNewer("1.0b1", than: "1.0b2"))
    }

    // MARK: - Scheduling

    @Test func theCheckRunsAtMostOnceADay() {
        let now = Date()
        #expect(ExtensionUpdates.isDue(lastCheck: nil, now: now))
        #expect(!ExtensionUpdates.isDue(lastCheck: now.addingTimeInterval(-60), now: now))
        #expect(ExtensionUpdates.isDue(lastCheck: now.addingTimeInterval(-ExtensionUpdates.checkInterval), now: now))
        // The button in Settings does not wait for the day to pass.
        #expect(ExtensionUpdates.isDue(lastCheck: now.addingTimeInterval(-60), now: now, force: true))
        // A clock that moved backwards would otherwise park the check until the
        // original date came round again.
        #expect(ExtensionUpdates.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }

    // MARK: - The check itself

    @Test func onlyGeckoIDedExtensionsWithSomethingNewerAreOffered() async {
        let installed = [
            self.installed(id: "old", version: "1.0", geckoID: "old@example.com"),
            self.installed(id: "current", version: "3.0", geckoID: "current@example.com"),
            self.installed(id: "folder-install", version: "1.0", geckoID: nil),
            self.installed(id: "unversioned", version: nil, geckoID: "unversioned@example.com")
        ]
        var asked: [String] = []
        let found = await ExtensionUpdates.check(installed) { guid in
            asked.append(guid)
            return self.addon(version: guid == "old@example.com" ? "1.1" : "3.0")
        }

        #expect(found == ["old": "1.1"])
        #expect(asked == ["old@example.com", "current@example.com"], "no id, no listing to ask about")
    }

    // MARK: - Replacing the files

    /// The folder id is the extension's `uniqueIdentifier`, which is what WebKit keys
    /// its storage on, so an update has to land in the same folder. Anything the old
    /// version left behind goes with it.
    @Test func updatingReplacesTheFolderContentsInPlace() throws {
        let installed = try makeFolder(version: "1.0", extras: ["stale.js": "// old"])
        defer { try? FileManager.default.removeItem(at: installed) }
        let next = try makeFolder(version: "2.0")
        defer { try? FileManager.default.removeItem(at: next) }
        let archive = try zip(next)
        defer { try? FileManager.default.removeItem(at: archive) }

        try ExtensionManager.replaceContents(of: installed, withArchive: archive)

        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: installed.appendingPathComponent("manifest.json"))
        ) as? [String: Any]
        #expect(manifest?["version"] as? String == "2.0")
        #expect(
            !FileManager.default.fileExists(atPath: installed.appendingPathComponent("stale.js").path),
            "a file the old version shipped must not survive into the new one"
        )
    }

    /// A download that unpacks to something that is not an extension must leave the
    /// working copy exactly as it was.
    @Test func aBadArchiveLeavesTheInstalledCopyAlone() throws {
        let installed = try makeFolder(version: "1.0")
        defer { try? FileManager.default.removeItem(at: installed) }
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-junk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("nothing here".utf8).write(to: junk.appendingPathComponent("readme.txt"))
        defer { try? FileManager.default.removeItem(at: junk) }
        let archive = try zip(junk)
        defer { try? FileManager.default.removeItem(at: archive) }

        #expect(throws: (any Error).self) {
            try ExtensionManager.replaceContents(of: installed, withArchive: archive)
        }
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: installed.appendingPathComponent("manifest.json"))
        ) as? [String: Any]
        #expect(manifest?["version"] as? String == "1.0")
    }

    private func makeFolder(version: String, extras: [String: String] = [:]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Updatable", "version": version]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("manifest.json"))
        for (name, contents) in extras {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    /// The same shape an .xpi has: a plain zip of the extension's own files.
    private func zip(_ directory: URL) throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-update-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", directory.path, archive.path]
        try process.run()
        process.waitUntilExit()
        return archive
    }

    /// AMO being unreachable means no updates were found, never an error in the user's
    /// face, and one add-on's failure must not stop the rest being checked.
    @Test func aFailedLookupIsSkippedRatherThanFatal() async {
        struct Offline: Error {}
        let installed = [
            self.installed(id: "broken", version: "1.0", geckoID: "broken@example.com"),
            self.installed(id: "fine", version: "1.0", geckoID: "fine@example.com")
        ]
        let found = await ExtensionUpdates.check(installed) { guid in
            if guid == "broken@example.com" {
                throw Offline()
            }
            return self.addon(version: "2.0")
        }
        #expect(found == ["fine": "2.0"])

        // A listing with no version at all says nothing about what is installed.
        let versionless = await ExtensionUpdates.check([self.installed(
            id: "fine", version: "1.0", geckoID: "fine@example.com"
        )]) { _ in self.addon(version: nil) }
        #expect(versionless.isEmpty)
    }
}
