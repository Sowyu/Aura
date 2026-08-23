import Foundation
@testable import Aura
import Testing

@Suite("Page tool internal routes")
struct PageToolRouteTests {
    @Test("view source and reader addresses round trip their target")
    func roundTrip() throws {
        let target = try #require(URL(string: "https://example.test/a/b?x=1&y=2#frag"))

        let source = URL.oraViewSource(of: target)
        #expect(source.isOraInternal)
        #expect(source.isOraViewSource)
        #expect(!source.isOraReader)
        #expect(source.oraPageToolTarget == target)

        let reader = URL.oraReader(of: target)
        #expect(reader.isOraReader)
        #expect(!reader.isOraViewSource)
        #expect(reader.oraPageToolTarget == target)
    }

    @Test("reserved characters in the target survive the escaping")
    func escaping() throws {
        let awkward = try #require(URL(string: "https://example.test/s?q=a+b%2Bc&r=d/e#z"))
        #expect(URL.oraViewSource(of: awkward).oraPageToolTarget == awkward)
        // Nothing that could be read as a second parameter is left unescaped.
        let raw = URL.oraViewSource(of: awkward).absoluteString
        #expect(raw.hasPrefix("aura://view-source?url="))
        #expect(!raw.dropFirst("aura://view-source?url=".count).contains("&"))
    }

    @Test("a typed page tool address is a URL, not a search")
    func typedAddress() throws {
        let typed = "aura://view-source?url=https%3A%2F%2Fexample.test%2F"
        let parsed = try #require(constructURL(from: typed))
        #expect(parsed.isOraViewSource)
        #expect(parsed.oraPageToolTarget?.absoluteString == "https://example.test/")
        #expect(isValidURL(typed))
    }

    @Test("the legacy ora:// spelling is accepted and normalises")
    func legacyScheme() throws {
        let legacy = try #require(URL(string: "ora://reader?url=https%3A%2F%2Fexample.test%2F"))
        #expect(legacy.isOraReader)
        #expect(legacy.canonicalOraInternal.absoluteString.hasPrefix("aura://reader?url="))
        #expect(legacy.canonicalOraInternal.isOraReader)
    }

    @Test("the other internal pages and the web are not page tools")
    func neighbours() throws {
        #expect(!URL.oraHome.isOraViewSource)
        #expect(!URL.oraHome.isOraReader)
        #expect(URL.oraHome.oraPageToolTarget == nil)
        #expect(!URL.oraSettings().isOraReader)

        let web = try #require(URL(string: "https://example.test/reader"))
        #expect(!web.isOraReader)
        #expect(!web.isOraViewSource)
    }

    @Test("an address with no target reports none rather than guessing one")
    func missingTarget() throws {
        let bare = try #require(URL(string: "aura://reader"))
        #expect(bare.isOraReader)
        #expect(bare.oraPageToolTarget == nil)
    }
}
