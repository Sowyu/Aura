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

    @Test func reportsWindowsAndTabsToLoadedExtension() async throws {
        guard #available(macOS 15.4, *) else {
            Issue.record("Requires macOS 15.4; host OS too old to run this check")
            return
        }
        let dir = try makeFixtureExtension()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ExtensionEngine()
        _ = try await engine.load(directory: dir, id: "window-test-ext")
        let context = try #require(engine.controller.extensionContexts.first)

        let window = StubExtensionWindow()
        engine.controller.didOpenWindow(window)
        engine.controller.didFocusWindow(window)

        // The test host is the app itself, so a real browser window may also be
        // registered; assert on this window rather than on the total.
        #expect(context.openWindows.contains { ($0 as AnyObject) === window })
        #expect(context.focusedWindow === window)

        let tab = window.stubTab
        engine.controller.didOpenTab(tab)
        engine.controller.didActivateTab(tab, previousActiveTab: nil)

        #expect(context.openTabs.contains { ($0 as AnyObject) === tab })
        // A manifest with no action key still exposes the default action.
        #expect(context.action(for: tab) != nil)

        engine.controller.didCloseTab(tab, windowIsClosing: false)
        engine.controller.didCloseWindow(window)
        #expect(!context.openWindows.contains { ($0 as AnyObject) === window })

        engine.unload(id: "window-test-ext")
    }

    @Test func managerAttachSkipsPrivateProfiles() {
        guard #available(macOS 15.4, *) else { return }
        let privateConfig = WKWebViewConfiguration()
        ExtensionManager.shared.attach(to: privateConfig, isPrivate: true)
        #expect(privateConfig.webExtensionController == nil)
    }
}

/// Minimal `WKWebExtensionTab`/`WKWebExtensionWindow` pair. The real adapters need a
/// SwiftData `Tab` and a `TabManager`; these only need to prove the controller
/// bookkeeping runs, so they stay standalone.
@available(macOS 15.4, *)
@MainActor
private final class StubExtensionTab: NSObject, WKWebExtensionTab {
    weak var parentWindow: StubExtensionWindow?

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { parentWindow }
    func url(for context: WKWebExtensionContext) -> URL? { URL(string: "https://example.com/") }
    func title(for context: WKWebExtensionContext) -> String? { "Example" }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { true }
}

@available(macOS 15.4, *)
@MainActor
private final class StubExtensionWindow: NSObject, WKWebExtensionWindow {
    let stubTab = StubExtensionTab()

    override init() {
        super.init()
        stubTab.parentWindow = self
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [stubTab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { stubTab }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
}
