import AppKit
import Foundation
@testable import Aura
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
            "name": "Aura Test Extension",
            "version": "1.0",
            "permissions": ["storage"],
            "host_permissions": ["*://example.com/*"],
            "content_scripts": [
                ["matches": ["*://example.com/*"], "js": ["content.js"]]
            ]
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

        #expect(loaded.displayName == "Aura Test Extension")
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

    /// Removing an extension used to go through the lazily creating `engine`
    /// accessor, which built a `WKWebExtensionController` (and with it a whole
    /// extension process) just to unload something that was never loaded.
    @Test func removingANeverLoadedExtensionBuildsNoController() {
        guard #available(macOS 15.4, *) else { return }
        let manager = ExtensionManager()
        #expect(manager.loadedEngine == nil, "a fresh manager has no engine yet")

        manager.removeExtension("never-installed")
        #expect(manager.loadedEngine == nil)
    }

    // MARK: - Private windows

    /// Private windows used to get no extension controller at all, so "run in private
    /// windows" was not a thing a user could be granted. The gate is the per-context
    /// private-data flag now, and it has to follow the grant in both directions.
    @Test func privateDataAccessFollowsTheGrant() async throws {
        guard #available(macOS 15.4, *) else {
            Issue.record("Requires macOS 15.4; host OS too old to run this check")
            return
        }
        let dir = try makeFixtureExtension()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ExtensionEngine()
        _ = try await engine.load(directory: dir, id: "private-ext", privateAccess: true)
        let context = try #require(engine.context(for: "private-ext"))
        #expect(context.hasAccessToPrivateData)

        engine.setPrivateAccess(false, for: "private-ext")
        #expect(!context.hasAccessToPrivateData)

        engine.unload(id: "private-ext")
    }

    /// Loading with no grant is the default, and re-loading an already-loaded id must
    /// not quietly re-grant it.
    @Test func privateDataAccessIsOffByDefault() async throws {
        guard #available(macOS 15.4, *) else { return }
        let dir = try makeFixtureExtension()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = ExtensionEngine()
        _ = try await engine.load(directory: dir, id: "normal-ext")
        let context = try #require(engine.context(for: "normal-ext"))
        #expect(!context.hasAccessToPrivateData)

        _ = try await engine.load(directory: dir, id: "normal-ext", privateAccess: true)
        #expect(context.hasAccessToPrivateData, "a reload has to carry the current grant")

        engine.unload(id: "normal-ext")
    }

    /// Adapters are shared by every loaded extension, so the per-extension filter is
    /// what stops one extension's grant from leaking to all of them.
    @Test func privateWindowTabsAreHiddenWithoutAGrant() {
        guard #available(macOS 15.4, *) else { return }
        #expect(ExtensionWindowAdapter.showsTabs(inPrivateWindow: false, contextHasPrivateAccess: false))
        #expect(ExtensionWindowAdapter.showsTabs(inPrivateWindow: false, contextHasPrivateAccess: true))
        #expect(!ExtensionWindowAdapter.showsTabs(inPrivateWindow: true, contextHasPrivateAccess: false))
        #expect(ExtensionWindowAdapter.showsTabs(inPrivateWindow: true, contextHasPrivateAccess: true))
    }

    /// The manifest read used to happen inside the first `BrowserPage.init`, on the main
    /// actor. `prepare` is what moved off it, so it has to be callable from a detached
    /// task and return everything the main actor needs to build the row.
    @Test func manifestScanRunsOffTheMainActor() async throws {
        let directory = try makeFixtureExtension()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scanned = await Task.detached {
            ExtensionManager.prepare(at: directory, patchesShim: false)
        }.value

        #expect(scanned.id == directory.lastPathComponent)
        #expect(scanned.displayName == "Aura Test Extension")
        #expect(scanned.displayVersion == "1.0")
        #expect(scanned.directoryURL == directory)
    }

    /// A folder with no manifest still produces an entry, so the row shows the folder
    /// name rather than the scan dropping it silently.
    @Test func scanOfAFolderWithoutAManifestKeepsTheFolderName() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-empty-extension-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scanned = await Task.detached {
            ExtensionManager.prepare(at: directory, patchesShim: false)
        }.value

        #expect(scanned.displayName == nil)
        #expect(scanned.geckoID == nil)
        #expect(scanned.id == directory.lastPathComponent)
    }

    // MARK: - Install consent

    private func consentRequest(
        id: String,
        version: String,
        permissions: [String],
        source: ExtensionInstallSource = .folder("Aura Test Extension")
    ) -> ExtensionConsentRequest {
        ExtensionConsentRequest(
            id: id,
            displayName: "Aura Test Extension",
            displayDescription: nil,
            version: version,
            source: source,
            permissions: permissions
        )
    }

    /// An id nobody has agreed to yet must never reach `engine.load` unasked.
    @Test func firstInstallOfAnIDAsksTheUser() {
        let request = consentRequest(id: "test-ext", version: "1.0", permissions: ["storage"])
        #expect(ExtensionConsent.decision(for: request, stored: nil) == .prompt)
    }

    /// Re-enabling or relaunching with the same build is not a new install.
    @Test func consentedVersionAndPermissionsLoadHeadless() {
        let request = consentRequest(id: "test-ext", version: "1.0", permissions: ["storage", "tabs"])
        let stored = ExtensionConsentRecord(version: "1.0", permissionsHash: request.permissionsHash)
        #expect(ExtensionConsent.decision(for: request, stored: stored) == .load)

        // Same permissions, newer build: an update on its own is not worth a prompt.
        let updated = consentRequest(id: "test-ext", version: "1.1", permissions: ["tabs", "storage"])
        #expect(ExtensionConsent.decision(for: updated, stored: stored) == .load)
    }

    /// The case the gate exists for: an update quietly asking for more.
    @Test func grownPermissionsAskAgain() {
        let installed = consentRequest(id: "test-ext", version: "1.0", permissions: ["storage"])
        let stored = ExtensionConsentRecord(version: "1.0", permissionsHash: installed.permissionsHash)

        let grown = consentRequest(
            id: "test-ext",
            version: "1.1",
            permissions: ["storage", "<all_urls>"]
        )
        #expect(ExtensionConsent.decision(for: grown, stored: stored) == .prompt)
    }

    /// uBlock Origin Lite ships inside the app, so installing Aura is the consent.
    @Test func bundledExtensionNeedsNoConsent() {
        let request = consentRequest(
            id: BundledExtensions.folderID,
            version: "2026.820.1159",
            permissions: ["declarativeNetRequest", "scripting", "<all_urls>"],
            source: .bundled
        )
        #expect(ExtensionConsent.decision(for: request, stored: nil) == .load)
    }

    /// The bundled blocker is recognised by folder or by gecko id, and nothing else
    /// is. A stale id from the blocker Aura used to ship must not pre-consent
    /// anything a user later drops into that folder name.
    @Test func onlyTheBundledBlockerIsPreConsented() {
        #expect(BundledExtensions.isBundled(id: BundledExtensions.folderID, geckoID: nil))
        #expect(BundledExtensions.isBundled(id: "renamed-folder", geckoID: BundledExtensions.geckoID))
        #expect(!BundledExtensions.isBundled(id: BundledExtensions.legacyFolderName, geckoID: nil))
        #expect(!BundledExtensions.isBundled(id: "ublock-origin", geckoID: "uBlock0@raymondhill.net"))
    }

    /// The one-time swap: the old blocker goes only when Aura is the one that put it
    /// there, and the new one is unpacked only until its marker is set.
    @Test func replacementPlanRemovesOnlyWhatAuraInstalled() {
        #expect(
            BundledExtensions.replacementPlan(oldMarker: true, oldFolderExists: true, newMarker: false)
                == .init(removesLegacy: true, installsNew: true)
        )
        // Marker set, folder already gone: the user removed it, nothing to do.
        #expect(
            BundledExtensions.replacementPlan(oldMarker: true, oldFolderExists: false, newMarker: true)
                == .init(removesLegacy: false, installsNew: false)
        )
        // A folder with no marker behind it is the user's own install and stays.
        #expect(
            BundledExtensions.replacementPlan(oldMarker: false, oldFolderExists: true, newMarker: true)
                == .init(removesLegacy: false, installsNew: false)
        )
        // Fresh profile: nothing to remove, everything to install.
        #expect(
            BundledExtensions.replacementPlan(oldMarker: false, oldFolderExists: false, newMarker: false)
                == .init(removesLegacy: false, installsNew: true)
        )
    }

    // MARK: - Row notes

    /// The row used to take a snapshot of `context.errors` three seconds after loading
    /// and never look again. It is rewritten on every error notification now, and this
    /// is the wording it produces.
    @Test func theRowNoteJoinsCompatibilityAndTheFirstRuntimeError() {
        #expect(ExtensionManager.rowNote(compatibility: nil, errors: []) == nil)
        #expect(ExtensionManager.rowNote(compatibility: "WebKit has no: proxy.", errors: [])
            == "WebKit has no: proxy.")
        // Only the first error: the row is two lines, and a wedged background script
        // reports the same failure a hundred times.
        #expect(ExtensionManager.rowNote(compatibility: nil, errors: ["boom", "again"]) == "Runtime: boom")
        #expect(ExtensionManager.rowNote(compatibility: "Partial.", errors: ["boom"]) == "Partial. Runtime: boom")
    }

    // MARK: - Uninstall

    /// Removing an extension deleted its folder and left everything else: the consent
    /// record, the private-window grant, the update offer and every key the user had
    /// bound to its commands. A reinstall of the same id then inherited decisions made
    /// about the copy that was thrown away.
    @Test @MainActor func removingAnExtensionForgetsEveryRecordAuraKept() throws {
        guard #available(macOS 15.4, *) else { return }
        let id = "aura-uninstall-test"
        let settings = SettingsStore.shared
        let previousConsent = settings.extensionConsent
        let previousGrants = settings.extensionPrivateWindowGrants
        let previousUpdates = settings.extensionAvailableUpdates
        defer {
            settings.extensionConsent = previousConsent
            settings.extensionPrivateWindowGrants = previousGrants
            settings.extensionAvailableUpdates = previousUpdates
        }

        settings.extensionConsent[id] = ExtensionConsentRecord(version: "1.0", permissionsHash: "abc")
        settings.extensionPrivateWindowGrants.insert(id)
        settings.extensionAvailableUpdates[id] = "2.0"

        let binding = ExtensionCommandShortcut(
            id: ExtensionCommandShortcut.id(extensionID: id, commandID: "toggle"),
            extensionID: id,
            commandID: "toggle",
            title: "Test: Toggle",
            suggested: nil
        ).definition
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
            windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j",
            isARepeat: false, keyCode: 38
        ))
        CustomKeyboardShortcutManager.shared.setCustomShortcut(for: binding, event: event)
        #expect(CustomKeyboardShortcutManager.shared.getShortcut(id: binding.id) != nil)

        let manager = ExtensionManager()
        manager.removeExtension(id)

        #expect(settings.extensionConsent[id] == nil)
        #expect(!settings.extensionPrivateWindowGrants.contains(id))
        #expect(settings.extensionAvailableUpdates[id] == nil)
        #expect(CustomKeyboardShortcutManager.shared.getShortcut(id: binding.id) == nil)
        #expect(manager.loadedEngine == nil, "removing an extension that never loaded builds no controller")
    }

    /// Manifests list permissions in whatever order they please, and a reorder is
    /// not a permission change.
    @Test func permissionHashIgnoresOrderAndDuplicates() {
        #expect(
            ExtensionConsent.permissionsHash(["tabs", "storage", "tabs"])
                == ExtensionConsent.permissionsHash(["storage", "tabs"])
        )
        #expect(ExtensionConsent.permissionsHash(["tabs"]) != ExtensionConsent.permissionsHash(["storage"]))
    }

    // MARK: - Page origin

    /// The origin an extension's own pages load from has to be the same one next
    /// launch, or every address that outlived the session — a restored dashboard
    /// tab, a bookmark — points at an extension nothing answers for.
    @Test func extensionPageOriginIsTheSameEveryLaunch() throws {
        let first = try #require(ExtensionOrigin.baseURL(for: "ublock-origin-9f21ab3c"))
        let again = try #require(ExtensionOrigin.baseURL(for: "ublock-origin-9f21ab3c"))
        #expect(first == again)

        let other = try #require(ExtensionOrigin.baseURL(for: "ublock-origin-lite-9f21ab3c"))
        #expect(first != other, "two extensions cannot share an origin")
    }

    /// WebKit takes the base URL apart itself: the scheme is its own, the host is the
    /// identifier, and it rejects a path, query or fragment.
    @Test func extensionPageOriginIsShapedTheWayWebKitWantsIt() throws {
        let url = try #require(ExtensionOrigin.baseURL(for: "aura test extension/../.."))
        #expect(url.scheme == "webkit-extension")
        #expect(url.path.isEmpty)
        #expect(url.query == nil)
        #expect(url.fragment == nil)

        // A folder name is not a host, so the host is a digest of it, in the UUID
        // shape WebKit generates for itself.
        let host = try #require(url.host)
        #expect(host == ExtensionOrigin.host(for: "aura test extension/../.."))
        #expect(UUID(uuidString: host) != nil, "got \(host)")
        #expect(host == host.lowercased())
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
