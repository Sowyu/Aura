import Foundation
@testable import Aura
import Testing

@Suite("Page tool internal routes")
struct PageToolRouteTests {
    @Test("view source and reader addresses round trip their target")
    func roundTrip() throws {
        let target = try #require(URL(string: "https://example.test/a/b?x=1&y=2#frag"))

        let source = URL.auraViewSource(of: target)
        #expect(source.isAuraInternal)
        #expect(source.isAuraViewSource)
        #expect(!source.isAuraReader)
        #expect(source.auraPageToolTarget == target)

        let reader = URL.auraReader(of: target)
        #expect(reader.isAuraReader)
        #expect(!reader.isAuraViewSource)
        #expect(reader.auraPageToolTarget == target)
    }

    @Test("reserved characters in the target survive the escaping")
    func escaping() throws {
        let awkward = try #require(URL(string: "https://example.test/s?q=a+b%2Bc&r=d/e#z"))
        #expect(URL.auraViewSource(of: awkward).auraPageToolTarget == awkward)
        // Nothing that could be read as a second parameter is left unescaped.
        let raw = URL.auraViewSource(of: awkward).absoluteString
        #expect(raw.hasPrefix("aura://view-source?url="))
        #expect(!raw.dropFirst("aura://view-source?url=".count).contains("&"))
    }

    @Test("a typed page tool address is a URL, not a search")
    func typedAddress() throws {
        let typed = "aura://view-source?url=https%3A%2F%2Fexample.test%2F"
        let parsed = try #require(constructURL(from: typed))
        #expect(parsed.isAuraViewSource)
        #expect(parsed.auraPageToolTarget?.absoluteString == "https://example.test/")
        #expect(isValidURL(typed))
    }

    @Test("the legacy ora:// spelling is accepted and normalises")
    func legacyScheme() throws {
        let legacy = try #require(URL(string: "ora://reader?url=https%3A%2F%2Fexample.test%2F"))
        #expect(legacy.isAuraReader)
        #expect(legacy.canonicalAuraInternal.absoluteString.hasPrefix("aura://reader?url="))
        #expect(legacy.canonicalAuraInternal.isAuraReader)
    }

    @Test("the other internal pages and the web are not page tools")
    func neighbours() throws {
        #expect(!URL.auraHome.isAuraViewSource)
        #expect(!URL.auraHome.isAuraReader)
        #expect(URL.auraHome.auraPageToolTarget == nil)
        #expect(!URL.auraSettings().isAuraReader)

        let web = try #require(URL(string: "https://example.test/reader"))
        #expect(!web.isAuraReader)
        #expect(!web.isAuraViewSource)
    }

    @Test("an address with no target reports none rather than guessing one")
    func missingTarget() throws {
        let bare = try #require(URL(string: "aura://reader"))
        #expect(bare.isAuraReader)
        #expect(bare.auraPageToolTarget == nil)
    }
}
