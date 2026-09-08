import AppKit
import Foundation
import Testing
import WebKit
@testable import Aura

struct SettingsImportValidationTests {
    @Test func malformedImportsDoNotPartiallyChangePreferences() throws {
        let suite = "aura.audit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("before", forKey: "browser.homePage")

        let invalid: [[String: Any]] = [
            ["format": 1, "app": "Other", "values": [:], "data": [:]],
            ["format": 0, "app": "Aura", "values": [:], "data": [:]],
            ["format": 1, "app": "Aura", "values": ["nested": [NSNull()]], "data": [:]],
            [
                "format": 1,
                "app": "Aura",
                "values": ["browser.homePage": "after"],
                "data": ["invalid": "not base64!"]
            ],
            ["format": 1, "app": "Aura", "values": ["duplicate": 1], "data": ["duplicate": "eA=="]]
        ]
        for document in invalid {
            let data = try JSONSerialization.data(withJSONObject: document)
            #expect(throws: SettingsBackupError.self) { try SettingsBackup.apply(data, to: defaults) }
            #expect(defaults.string(forKey: "browser.homePage") == "before")
        }
        #expect(!SettingsBackup.isExportable("files.accessBookmarks"))
    }
}

struct AddonResponseValidationTests {
    @Test func listingURLsRequireTheExactHTTPSHost() {
        #expect(FirefoxAddonStore.slug(fromPageURL: "https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/")
            == "ublock-origin")
        for url in [
            "https://eviladdons.mozilla.org/addon/ublock-origin/",
            "https://addons.mozilla.org.evil.test/addon/ublock-origin/",
            "http://addons.mozilla.org/addon/ublock-origin/"
        ] {
            #expect(FirefoxAddonStore.slug(fromPageURL: url) == nil)
        }
    }

    @Test func failedDownloadsAreRejectedBeforeInstallation() throws {
        let secure = try #require(URL(string: "https://addons.mozilla.org/file.xpi"))
        for code in [200, 404, 500] {
            let response = try #require(HTTPURLResponse(
                url: secure,
                statusCode: code,
                httpVersion: nil,
                headerFields: nil
            ))
            if code == 200 {
                try FirefoxAddonStore.validate(response)
            } else {
                #expect(throws: URLError.self) { try FirefoxAddonStore.validate(response) }
            }
        }
        let insecure = try #require(URL(string: "http://example.test/file.xpi"))
        let response = try #require(HTTPURLResponse(
            url: insecure,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        #expect(throws: URLError.self) { try FirefoxAddonStore.validate(response) }
    }
}

struct ExtensionResourceBoundaryTests {
    @Test func htmlPatchingCannotEscapeTheExtensionDirectory() {
        let root = URL(fileURLWithPath: "/tmp/aura-audit-extension", isDirectory: true)
        #expect(ExtensionShim.containsResource(root.appendingPathComponent("pages/popup.html"), in: root))
        #expect(!ExtensionShim.containsResource(root.appendingPathComponent("../victim.html"), in: root))
        #expect(!ExtensionShim.containsResource(
            URL(fileURLWithPath: "/tmp/aura-audit-extension-other/page.html"),
            in: root
        ))
        #expect(!ExtensionShim.containsResource(root, in: root))
    }
}

@Suite(.serialized)
struct MotionSettingSynchronizationTests {
    @Test func concurrentReadsAndWritesUseTheSameSetting() {
        let original = AnimationSettings.reduceMotion
        defer { AnimationSettings.reduceMotionDidChange(to: original) }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            AnimationSettings.reduceMotionDidChange(to: index.isMultiple(of: 2))
            _ = AnimationSettings.duration(1)
        }
        AnimationSettings.reduceMotionDidChange(to: true)
        #expect(AnimationSettings.duration(1) == 0)
        AnimationSettings.reduceMotionDidChange(to: false)
        #expect(AnimationSettings.duration(1) == (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1))
    }
}

@MainActor
struct FileGrantLifetimeTests {
    @Test func rememberingOpensAccessOnceAndForgettingReleasesIt() throws {
        let suite = "aura.audit.files.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = URL(fileURLWithPath: "/tmp/aura-audit-example.pdf")
        var starts = 0
        var stops = 0
        let store = FileAccessStore(
            defaults: defaults,
            makeBookmark: { _ in Data([1]) },
            resolveBookmark: { _ in (file, false) },
            start: { _ in starts += 1
                return true
            },
            stop: { _ in stops += 1 }
        )
        store.remember(file)
        #expect(starts == 1)
        #expect(store.beginAccess(to: file))
        #expect(starts == 1)
        store.forget(file)
        #expect(stops == 1)
        #expect(!store.beginAccess(to: file))
    }

    @Test func aFailedGrantIsNotReportedAsOpen() throws {
        let suite = "aura.audit.failed-grant.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = URL(fileURLWithPath: "/tmp/aura-audit-example.pdf")
        let store = FileAccessStore(
            defaults: defaults,
            makeBookmark: { _ in Data([1]) },
            resolveBookmark: { _ in (file, false) },
            start: { _ in false },
            stop: { _ in Issue.record("An unopened grant must not be stopped") }
        )
        store.remember(file)
        #expect(!store.beginAccess(to: file))
    }
}

@MainActor
struct PasswordWorldTests {
    @Test func websitesCannotReplaceThePasswordBridge() async throws {
        let script = try #require(AuraBrowserScripts.userScripts().first { $0.name == "aura-password-manager" })
        let diagnosticScript = BrowserUserScript(
            name: script.name,
            source: "try {\n\(script.source)\n} catch (error) { window.__passwordError = String(error.stack || error); }",
            injectionTime: script.injectionTime,
            forMainFrameOnly: script.forMainFrameOnly,
            usesPasswordWorld: script.usesPasswordWorld
        )
        let server = try LocalHTTPServer(html: "<html><title>audit fixture</title><input type='password'></html>")
        let port = try await server.start()
        defer { server.stop() }
        let page = BrowserPage(
            profile: BrowserEngineProfile(identifier: UUID(), isPrivate: true),
            configuration: .auraDefault(userScripts: [diagnosticScript], privacySettings: SpacePrivacySettings()),
            delegate: nil
        )
        let view = page.auraWebView
        // WebKit throttles views without a window, including document-end scripts.
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = frame
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            page.teardown()
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/index.html"))
        page.load(URLRequest(url: url))
        var ready = false
        for _ in 0 ..< 100 {
            let value = try? await view.evaluateJavaScript(
                "typeof window.__auraPasswordManager", in: nil, contentWorld: BrowserPage.passwordWorld
            )
            if value as? String == "object" { ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let diagnostic = try await view.evaluateJavaScript(
            """
            JSON.stringify({url: location.href, state: document.readyState,
                installed: window.__auraPasswordManagerInstalled,
                handler: typeof window.webkit?.messageHandlers?.passwordManager,
                error: window.__passwordError})
            """, in: nil, contentWorld: BrowserPage.passwordWorld
        )
        try #require(ready, "Password script did not load: \(String(describing: diagnostic))")
        let exposed = try await view.evaluateJavaScript(
            "typeof window.__auraPasswordManager + ':' + typeof window.webkit.messageHandlers.passwordManager"
        )
        #expect(exposed as? String == "undefined:undefined")
        _ = try await view.evaluateJavaScript("window.__auraPasswordManager = { fillCredentials: 'hijacked' }")
        let isolated = try await view.evaluateJavaScript(
            "typeof window.__auraPasswordManager.fillCredentials", in: nil, contentWorld: BrowserPage.passwordWorld
        )
        #expect(isolated as? String == "function")
    }
}
