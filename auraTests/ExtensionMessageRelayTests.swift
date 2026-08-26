import Foundation
import Testing

@testable import Aura

/// The disk half of intra-extension messaging: getting Aura's shim in front of
/// every page an extension ships.
///
/// The WebKit half lives in `WebRequestBrokerTests`, which is serialized because
/// those tests share the broker's state file with each other.
@Suite
struct ExtensionPagePatchTests {
    @Test
    func shimGoesInFrontOfEveryPageTheExtensionShips() throws {
        let directory = try Self.makeExtension()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try ExtensionShim.apply(at: directory), "a popup alone is reason enough to patch")

        let popup = try String(contentsOf: directory.appendingPathComponent("popup.html"), encoding: .utf8)
        let shimAt = try #require(popup.range(of: "/aura-shim.js"))
        let roleAt = try #require(popup.range(of: "/aura-shim-page.js"))
        let ownScriptAt = try #require(popup.range(of: "popup.js"))
        #expect(roleAt.lowerBound < shimAt.lowerBound, "the role marker has to be set before the shim reads it")
        #expect(shimAt.lowerBound < ownScriptAt.lowerBound, "the shim has to run before the page does")

        // Nested, and never named by the manifest: uBlock Origin's dashboard
        // frames these, and each one connects on its own.
        let nested = try String(contentsOf: directory.appendingPathComponent("panes/pane.html"), encoding: .utf8)
        #expect(nested.contains("/aura-shim.js"))

        // A document with no script of its own cannot message anybody.
        let blank = try String(contentsOf: directory.appendingPathComponent("blank.html"), encoding: .utf8)
        #expect(!blank.contains("aura-shim"), "a scriptless placeholder should not open a native port")

        let role = try String(contentsOf: directory.appendingPathComponent("aura-shim-page.js"), encoding: .utf8)
        #expect(role.contains("__auraShimRole = 'page'"))
        #expect(role.contains("__auraManifest"), "pages need getManifest() too")
    }

    @Test
    func patchingPagesTwiceLeavesOneCopyOfTheTags() throws {
        let directory = try Self.makeExtension()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try ExtensionShim.apply(at: directory))
        let once = try String(contentsOf: directory.appendingPathComponent("popup.html"), encoding: .utf8)

        // Force the version gate open the way a shim bump does, then re-patch.
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        manifest[ExtensionShim.versionKey] = ExtensionShim.version - 1
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)

        #expect(try ExtensionShim.apply(at: directory))
        let twice = try String(contentsOf: directory.appendingPathComponent("popup.html"), encoding: .utf8)

        #expect(once == twice, "a re-patch must not stack a second pair of script tags")
        #expect(twice.components(separatedBy: "/aura-shim.js").count == 2, "exactly one shim tag")
    }

    @Test
    func extensionsWithNoPagesAndNoWebRequestAreLeftAlone() throws {
        let directory = try Self.makeExtension(includePages: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try ExtensionShim.apply(at: directory) == false)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("aura-shim.js").path))
    }

    /// An extension whose only claim on Aura is that it has pages: no
    /// webRequest anywhere, so it also proves the patch gate widened.
    static func makeExtension(includePages: Bool = true) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-relay-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("panes", isDirectory: true),
            withIntermediateDirectories: true
        )

        var manifest: [String: Any] = [
            "manifest_version": 2,
            "name": "Aura relay fixture",
            "version": "1.0",
            "permissions": ["storage"],
            "background": ["scripts": ["bg.js"]]
        ]
        if includePages {
            manifest["browser_action"] = ["default_popup": "popup.html"]
            manifest["options_ui"] = ["page": "options.html", "open_in_tab": true]
        }
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("manifest.json"))
        try "".write(to: directory.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8)

        let page = "<!doctype html><html><head><meta charset=\"utf-8\"></head>"
            + "<body><script src=\"popup.js\"></script></body></html>"
        for name in ["popup.html", "options.html", "panes/pane.html"] {
            try page.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "<!doctype html><html><body></body></html>".write(
            to: directory.appendingPathComponent("blank.html"), atomically: true, encoding: .utf8
        )
        return directory
    }
}
