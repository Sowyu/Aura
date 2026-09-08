import Foundation
@testable import Aura
import Testing

@Suite("aura:// internal URLs")
struct AuraInternalURLTests {
    @Test("settings URLs are recognised and carry their section")
    func settingsURLParsing() throws {
        let root = try #require(URL(string: "aura://settings"))
        #expect(root.isAuraInternal)
        #expect(root.isAuraSettings)
        #expect(root.auraSettingsSection == nil)

        let section = try #require(URL(string: "aura://settings/spaces"))
        #expect(section.isAuraSettings)
        #expect(section.auraSettingsSection == .spaces)

        let unknown = try #require(URL(string: "aura://settings/nope"))
        #expect(unknown.auraSettingsSection == nil)

        let web = try #require(URL(string: "https://example.com/settings"))
        #expect(!web.isAuraInternal)
        #expect(!web.isAuraSettings)
    }

    @Test("aura:// addresses are treated as URLs, not searches")
    func typedAddressIsAURL() {
        #expect(isValidURL("aura://settings"))
        #expect(constructURL(from: "aura://settings/extensions") == URL.auraSettings(section: .extensions))
        #expect(URL.auraSettings().absoluteString == "aura://settings")
    }

    @Test("home is an internal page of its own")
    func homeURLParsing() throws {
        #expect(URL.auraHome.absoluteString == "aura://home")
        #expect(URL.auraHome.isAuraInternal)
        #expect(URL.auraHome.isAuraHome)
        #expect(!URL.auraHome.isAuraSettings)
        #expect(!URL.auraSettings().isAuraHome)

        let legacy = try #require(URL(string: "ora://home"))
        #expect(legacy.isAuraHome)
        #expect(legacy.canonicalAuraInternal == URL.auraHome)

        #expect(isValidURL("aura://home"))
        #expect(constructURL(from: "aura://home") == URL.auraHome)
        #expect(constructURL(from: "ora://home") == URL.auraHome)

        let web = try #require(URL(string: "https://example.com/home"))
        #expect(!web.isAuraHome)
    }

    @Test("aura://extensions is the store page, ora:// spelling included")
    func extensionsStoreURL() throws {
        #expect(URL.auraExtensions.absoluteString == "aura://extensions")
        #expect(URL.auraExtensions.isAuraExtensions)
        #expect(!URL.auraExtensions.isAuraSettings)
        #expect(!URL.auraExtensions.isAuraHome)

        let legacy = try #require(URL(string: "ora://extensions"))
        #expect(legacy.isAuraExtensions)
        #expect(legacy.canonicalAuraInternal == URL.auraExtensions)
        #expect(constructURL(from: "aura://extensions") == URL.auraExtensions)

        let web = try #require(URL(string: "https://example.com/extensions"))
        #expect(!web.isAuraExtensions)
    }

    @Test("legacy ora:// addresses still resolve and normalise to aura://")
    func legacySchemeIsAccepted() throws {
        let legacy = try #require(URL(string: "ora://settings/spaces"))
        #expect(legacy.isAuraInternal)
        #expect(legacy.isAuraSettings)
        #expect(legacy.auraSettingsSection == .spaces)
        #expect(legacy.canonicalAuraInternal.absoluteString == "aura://settings/spaces")

        #expect(isValidURL("ora://settings"))
        #expect(constructURL(from: "ora://settings") == URL.auraSettings())
    }
}
