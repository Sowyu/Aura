import Foundation
@testable import Aura
import Testing

@MainActor
struct FirefoxAddonTests {
    @Test func parsesSlugFromListingURLs() {
        #expect(FirefoxAddonStore.slug(
            fromPageURL: "https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/"
        ) == "ublock-origin")
        #expect(FirefoxAddonStore.slug(
            fromPageURL: "https://addons.mozilla.org/firefox/addon/darkreader"
        ) == "darkreader")
        #expect(FirefoxAddonStore.slug(fromPageURL: "https://example.com/addon/foo") == nil)
        #expect(FirefoxAddonStore.slug(fromPageURL: "ublock") == nil)
    }

    @Test func unpacksZipAndFindsManifestRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-xpi-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Build a fixture "xpi": content nested one level deep, like some archives.
        let content = base.appendingPathComponent("src/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "name": "Zipped", "version": "1.0"}"#.utf8)
            .write(to: content.appendingPathComponent("manifest.json"))

        let archive = base.appendingPathComponent("fixture.xpi")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", base.appendingPathComponent("src").path, archive.path]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)

        let unpacked = base.appendingPathComponent("out", isDirectory: true)
        try XPIUnpacker.unpack(archive, to: unpacked)
        let root = try #require(XPIUnpacker.manifestRoot(in: unpacked))
        #expect(root.lastPathComponent == "inner")
    }

    /// Live end-to-end: search AMO, download a real Firefox extension, unpack
    /// it, and load it into WebKit. Passes vacuously offline.
    @Test func downloadsAndLoadsRealFirefoxExtension() async throws {
        guard #available(macOS 15.4, *) else { return }

        let results: [FirefoxAddon]
        do {
            results = try await FirefoxAddonStore.shared.search("dark reader")
        } catch {
            Issue.record("AMO unreachable (offline?): \(error.localizedDescription)")
            return
        }
        #expect(!results.isEmpty)
        let addon = try #require(results.first { $0.slug == "darkreader" } ?? results.first)
        let downloadURL = try #require(addon.downloadURL)

        let archive = try await FirefoxAddonStore.shared.downloadXPI(from: downloadURL)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-amo-test-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: staging)
        }

        try XPIUnpacker.unpack(archive, to: staging)
        let root = try #require(XPIUnpacker.manifestRoot(in: staging))

        let engine = ExtensionEngine()
        let loaded = try await engine.load(directory: root, id: "amo-test")
        #expect(loaded.displayName?.isEmpty == false)
        #expect(engine.controller.extensionContexts.count == 1)
        engine.unload(id: "amo-test")
    }
}
