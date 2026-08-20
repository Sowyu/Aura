import Foundation
@testable import Aura
import Testing

@Suite("aura:// internal URLs")
struct OraInternalURLTests {
    @Test("settings URLs are recognised and carry their section")
    func settingsURLParsing() throws {
        let root = try #require(URL(string: "aura://settings"))
        #expect(root.isOraInternal)
        #expect(root.isOraSettings)
        #expect(root.oraSettingsSection == nil)

        let section = try #require(URL(string: "aura://settings/spaces"))
        #expect(section.isOraSettings)
        #expect(section.oraSettingsSection == .spaces)

        let unknown = try #require(URL(string: "aura://settings/nope"))
        #expect(unknown.oraSettingsSection == nil)

        let web = try #require(URL(string: "https://example.com/settings"))
        #expect(!web.isOraInternal)
        #expect(!web.isOraSettings)
    }

    @Test("aura:// addresses are treated as URLs, not searches")
    func typedAddressIsAURL() {
        #expect(isValidURL("aura://settings"))
        #expect(constructURL(from: "aura://settings/extensions") == URL.oraSettings(section: .extensions))
        #expect(URL.oraSettings().absoluteString == "aura://settings")
    }

    @Test("legacy ora:// addresses still resolve and normalise to aura://")
    func legacySchemeIsAccepted() throws {
        let legacy = try #require(URL(string: "ora://settings/spaces"))
        #expect(legacy.isOraInternal)
        #expect(legacy.isOraSettings)
        #expect(legacy.oraSettingsSection == .spaces)
        #expect(legacy.canonicalOraInternal.absoluteString == "aura://settings/spaces")

        #expect(isValidURL("ora://settings"))
        #expect(constructURL(from: "ora://settings") == URL.oraSettings())
    }
}
