import Foundation
@testable import Aura
import Testing

@Suite("Clean link parameters")
struct LinkCleanerTests {
    private func clean(_ raw: String) throws -> String {
        let url = try #require(URL(string: raw))
        return LinkCleaner.clean(url).absoluteString
    }

    @Test("every named tracker and the utm_ family are stripped")
    func strippingTheKnownSet() throws {
        #expect(try clean("https://a.test/p?utm_source=x&utm_medium=y&id=7") == "https://a.test/p?id=7")
        #expect(try clean("https://a.test/p?fbclid=abc&id=7") == "https://a.test/p?id=7")
        #expect(try clean("https://a.test/p?gclid=abc&id=7") == "https://a.test/p?id=7")
        #expect(try clean("https://a.test/p?mc_cid=1&mc_eid=2&id=7") == "https://a.test/p?id=7")
        #expect(try clean("https://a.test/p?ref_src=twsrc&id=7") == "https://a.test/p?id=7")
        #expect(try clean("https://a.test/p?igshid=zz&id=7") == "https://a.test/p?id=7")
    }

    @Test("the whole query goes when nothing survives, brackets and all")
    func emptyQueryIsRemoved() throws {
        #expect(try clean("https://a.test/p?utm_source=x") == "https://a.test/p")
        #expect(try clean("https://a.test/p?utm_source=x#top") == "https://a.test/p#top")
    }

    @Test("a link with nothing to strip comes back untouched")
    func untrackedLinksAreLeftAlone() throws {
        #expect(try clean("https://a.test/p?id=7&q=hello") == "https://a.test/p?id=7&q=hello")
        #expect(try clean("https://a.test/p") == "https://a.test/p")
        #expect(try clean("https://a.test/") == "https://a.test/")
    }

    @Test("escaping in the parameters that stay is not rewritten")
    func encodingSurvives() throws {
        // A signature with a literal %2B in it is the case that decode-and-re-encode
        // silently breaks.
        let signed = "https://a.test/p?sig=aG%2Bk%3D&utm_source=news"
        #expect(try clean(signed) == "https://a.test/p?sig=aG%2Bk%3D")
        #expect(try clean("https://a.test/p?q=a+b&fbclid=1") == "https://a.test/p?q=a+b")
    }

    @Test("matching is case insensitive and prefix based")
    func matchingRules() {
        #expect(LinkCleaner.isTracking("UTM_Source"))
        #expect(LinkCleaner.isTracking("utm_anything_at_all"))
        #expect(LinkCleaner.isTracking("FBCLID"))
        #expect(!LinkCleaner.isTracking("utmost"))
        #expect(!LinkCleaner.isTracking("id"))
        #expect(!LinkCleaner.isTracking("reference"))
    }
}
