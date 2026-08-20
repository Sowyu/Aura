import Foundation
@testable import Ora
import Testing
import WebKit

/// Runtime verification that WebKit's native web-extension support loads an
/// unpacked manifest-v3 extension through our engine (auto-granting the
/// permissions it requests) and unloads it cleanly.
@MainActor
struct ExtensionEngineTests {
    private func makeFixtureExtension() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-test-extension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Ora Test Extension",
            "version": "1.0",
            "permissions": ["storage"],
            "host_permissions": ["*://example.com/*"],
            "content_scripts": [
                ["matches": ["*://example.com/*"], "js": ["content.js"]],
            ],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))
        try Data("document.title = 'ora-extension-was-here';".utf8)
            .write(to: dir.appendingPathComponent("content.js"))
        return dir
    }

    @Test func loadsUnpackedExtensionAndGrantsPermissions() async throws {
        guard #available(macOS 15.4, *) else {
            Issue.record("Requires macOS 15.4; host OS too old to run this check")
            return
        }
        let dir = try makeFixtureExtension()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ExtensionEngine()
        let loaded = try await engine.load(directory: dir, id: "test-ext")

        #expect(loaded.displayName == "Ora Test Extension")
        #expect(loaded.displayVersion == "1.0")
        #expect(engine.controller.extensionContexts.count == 1)

        let context = try #require(engine.controller.extensionContexts.first)
        #expect(context.uniqueIdentifier == "test-ext")
        #expect(context.permissionStatus(for: WKWebExtension.Permission("storage")) == .grantedExplicitly)
        #expect(!context.grantedPermissionMatchPatterns.isEmpty)

        engine.unload(id: "test-ext")
        #expect(engine.controller.extensionContexts.isEmpty)
    }

    @Test func managerAttachSkipsPrivateProfiles() {
        guard #available(macOS 15.4, *) else { return }
        let privateConfig = WKWebViewConfiguration()
        ExtensionManager.shared.attach(to: privateConfig, isPrivate: true)
        #expect(privateConfig.webExtensionController == nil)
    }
}
