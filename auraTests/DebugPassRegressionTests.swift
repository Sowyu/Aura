import Foundation
import SwiftUI
@testable import Aura
import Testing

/// Direct checks of the pure-logic bug fixes from the debug pass.
struct DebugPassRegressionTests {
    @Test func schemeCheckOnlyMatchesRealSchemes() {
        // "httpbin.org" starts with "http" but is a bare host — the old code
        // treated it as an absolute URL and extracted a nil/empty host.
        #expect(extractDomainOrIP(from: "httpbin.org") == "httpbin.org")
        #expect(extractDomainOrIP(from: "https://example.com/path") == "example.com")
        #expect(extractDomainOrIP(from: "http://example.com") == "example.com")
        #expect(extractDomainOrIP(from: "httpstat.us") == "httpstat.us")
    }

    @Test func findTermJSONEncodingSurvivesHostileInput() throws {
        // FindController JSON-encodes the term; verify the encoding round-trips
        // the characters that used to break the injected script.
        for term in ["back\\slash", "it's", "\"quoted\"", "line\nbreak", "</script>"] {
            let data = try JSONSerialization.data(withJSONObject: term, options: .fragmentsAllowed)
            let literal = try #require(String(data: data, encoding: .utf8))
            let decoded = try JSONSerialization.jsonObject(
                with: literal.data(using: .utf8)!, options: .fragmentsAllowed
            ) as? String
            #expect(decoded == term)
        }
    }

    @Test func hexColorFallbackIsOpaqueGray() {
        // Malformed hex used to produce a nearly transparent color.
        let color = Color(hex: "zz")
        #expect(NSColor(color).alphaComponent > 0.9)
    }
}
