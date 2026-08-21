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

    @Test func decodesSearchPageFields() throws {
        let json = #"""
        {
          "next": "https://addons.mozilla.org/api/v5/addons/search/?page=2",
          "results": [
            {
              "id": 607454,
              "slug": "ublock-origin",
              "name": {"en-US": "uBlock Origin"},
              "summary": {"en-US": "Finally, an efficient blocker."},
              "type": "extension",
              "average_daily_users": 7654321,
              "last_updated": "2024-05-21T10:33:00Z",
              "icon_url": "https://addons.mozilla.org/icon.png",
              "authors": [{"name": "Raymond Hill"}],
              "ratings": {"average": 4.78, "count": 18000},
              "current_version": {
                "version": "1.60.0",
                "file": {
                  "url": "https://addons.mozilla.org/file.xpi",
                  "permissions": ["webRequest", "webRequestBlocking"],
                  "optional_permissions": ["clipboardWrite"],
                  "host_permissions": ["<all_urls>"]
                }
              }
            }
          ]
        }
        """#

        let page = FirefoxAddonStore.parsePage(Data(json.utf8))
        #expect(page.hasMore)
        let addon = try #require(page.addons.first)
        #expect(addon.name == "uBlock Origin")
        #expect(addon.type == .extension)
        #expect(addon.authors == ["Raymond Hill"])
        #expect(addon.averageRating == 4.78)
        #expect(addon.dailyUsers == 7_654_321)
        #expect(addon.version == "1.60.0")
        #expect(addon.downloadURL?.lastPathComponent == "file.xpi")
        #expect(addon.permissions == ["webRequest", "webRequestBlocking"])
        #expect(addon.optionalPermissions == ["clipboardWrite"])
        #expect(addon.hostPermissions == ["<all_urls>"])
        #expect(addon.lastUpdated != nil)
        // The badge is decided from the record, before anything is downloaded.
        // Aura answers blocking webRequest itself now, so uBlock installs.
        #expect(ExtensionCompatibility.evaluate(addon) == .supported)
    }

    @Test func decodesAddonGUID() throws {
        let json = #"""
        {
          "results": [
            {
              "id": 607454,
              "slug": "ublock-origin",
              "guid": "uBlock0@raymondhill.net",
              "name": {"en-US": "uBlock Origin"}
            },
            {
              "id": 1,
              "slug": "no-guid",
              "name": {"en-US": "Old Payload"}
            }
          ]
        }
        """#

        let page = FirefoxAddonStore.parsePage(Data(json.utf8))
        #expect(page.addons.count == 2)
        #expect(page.addons[0].guid == "uBlock0@raymondhill.net")
        #expect(page.addons[1].guid == nil)
    }

    @Test func matchesOnGUIDBeforeDisplayName() {
        let addon = FirefoxAddon(id: 1, slug: "ublock-origin", name: "uBlock Origin",
                                 guid: "uBlock0@raymondhill.net")

        // AMO serves the name in the user's locale and add-ons get renamed, so the
        // guid has to win over a name that no longer lines up.
        #expect(ExtensionManager.matches(addon, installed(name: "uBlock Origin (Bloqueur)",
                                                          geckoID: "uBlock0@raymondhill.net")))

        // Two unrelated add-ons are free to ship the same name.
        #expect(!ExtensionManager.matches(addon, installed(name: "uBlock Origin",
                                                           geckoID: "impostor@example.com")))
    }

    @Test func matchesFallsBackToNameWithoutAGUID() {
        let withGUID = FirefoxAddon(id: 1, slug: "dark", name: "Dark Reader", guid: "addon@darkreader.org")
        let withoutGUID = FirefoxAddon(id: 1, slug: "dark", name: "Dark Reader")

        // A Chrome-shaped manifest declares no gecko id, and an older AMO payload
        // carries no guid. Either gap drops both sides back to the name.
        #expect(ExtensionManager.matches(withGUID, installed(name: "dark reader", geckoID: nil)))
        #expect(ExtensionManager.matches(withoutGUID, installed(name: "Dark Reader",
                                                               geckoID: "addon@darkreader.org")))
        #expect(!ExtensionManager.matches(withoutGUID, installed(name: "Something Else", geckoID: nil)))
    }

    private func installed(name: String, geckoID: String?) -> InstalledExtension {
        InstalledExtension(
            id: name,
            directoryURL: URL(fileURLWithPath: "/tmp/\(name)"),
            displayName: name,
            displayVersion: nil,
            geckoID: geckoID,
            isEnabled: true,
            icon: nil,
            loadError: nil
        )
    }

    @Test func compatibilityBadgeFollowsRequestedPermissions() {
        #expect(ExtensionCompatibility.evaluate(permissions: ["storage", "tabs"]) == .supported)
        #expect(ExtensionCompatibility.evaluate(permissions: ["proxy", "storage"]) == .partial(["proxy"]))

        // Blocking webRequest stopped being a WebKit gap once the injected
        // bundle started asking the extension. It follows the same setting the
        // native request filter does.
        let blocking = ExtensionCompatibility.evaluate(permissions: ["webRequest", "webRequestBlocking"])
        #expect(ExtensionCompatibility.supportsBlockingWebRequest)
        #expect(blocking == .supported)
        #expect(blocking.title == "Works on WebKit")

        // Themes list, but WebKit has no theme API, so they never install.
        let theme = ExtensionCompatibility.evaluate(FirefoxAddon(id: 1, slug: "dark", name: "Dark", type: .statictheme))
        #expect(theme.title == "Not supported")
        #expect(ExtensionCompatibility.evaluate(permissions: ["theme"]).allowsInstall == false)
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

    @Test func stripsCRXHeaderAndUnpacksTheZipBehindIt() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-crx-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let content = base.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "name": "Crx", "version": "1.0"}"#.utf8)
            .write(to: content.appendingPathComponent("manifest.json"))

        let zipURL = base.appendingPathComponent("fixture.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", content.path, zipURL.path]
        try zip.run()
        zip.waitUntilExit()

        // CRX3: "Cr24", version 3, header length, header bytes, then the zip.
        let signature = Data(repeating: 0xAB, count: 42)
        var crx = Data("Cr24".utf8)
        crx.append(contentsOf: [3, 0, 0, 0])
        crx.append(contentsOf: [UInt8(signature.count), 0, 0, 0])
        crx.append(signature)
        let zipData = try Data(contentsOf: zipURL)
        crx.append(zipData)
        #expect(try XPIUnpacker.crxPayload(crx) == zipData)

        let crxURL = base.appendingPathComponent("fixture.crx")
        try crx.write(to: crxURL)
        let stripped = try XPIUnpacker.zipFromCRX(crxURL)
        defer { try? FileManager.default.removeItem(at: stripped) }
        let unpacked = base.appendingPathComponent("out", isDirectory: true)
        try XPIUnpacker.unpack(stripped, to: unpacked)
        #expect(XPIUnpacker.manifestRoot(in: unpacked) != nil)
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
