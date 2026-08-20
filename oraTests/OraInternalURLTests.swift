import Foundation
@testable import Ora
import Testing

@Suite("ora:// internal URLs")
struct OraInternalURLTests {
    @Test("settings URLs are recognised and carry their section")
    func settingsURLParsing() throws {
        let root = try #require(URL(string: "ora://settings"))
        #expect(root.isOraInternal)
        #expect(root.isOraSettings)
        #expect(root.oraSettingsSection == nil)

        let section = try #require(URL(string: "ora://settings/spaces"))
        #expect(section.isOraSettings)
        #expect(section.oraSettingsSection == .spaces)

        let unknown = try #require(URL(string: "ora://settings/nope"))
        #expect(unknown.oraSettingsSection == nil)

        let web = try #require(URL(string: "https://example.com/settings"))
        #expect(!web.isOraInternal)
        #expect(!web.isOraSettings)
    }

    @Test("ora:// addresses are treated as URLs, not searches")
    func typedAddressIsAURL() {
        #expect(isValidURL("ora://settings"))
        #expect(constructURL(from: "ora://settings/extensions") == URL.oraSettings(section: .extensions))
        #expect(URL.oraSettings().absoluteString == "ora://settings")
    }
}
