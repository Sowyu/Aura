import Foundation
@testable import Aura
import SwiftData
import Testing

@MainActor
struct JavaScriptPolicyTests {
    private func makeService() throws -> JavaScriptPolicyService {
        let container = try ModelContainer(
            for: SiteJavaScriptRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return JavaScriptPolicyService(context: ModelContext(container))
    }

    @Test func followsTheGlobalDefaultAndPerSiteOverrides() throws {
        let service = try makeService()
        let store = SettingsStore.shared
        let baseline = store.blockJavaScriptByDefault
        defer { store.blockJavaScriptByDefault = baseline }

        let example = try #require(URL(string: "https://example.com/page"))
        let other = try #require(URL(string: "https://other.org"))

        store.blockJavaScriptByDefault = false
        #expect(service.isAllowed(for: example))

        store.blockJavaScriptByDefault = true
        #expect(!service.isAllowed(for: example))

        // A per-site allow beats the blocking default, and only for that site.
        service.setRule(host: "example.com", allowed: true)
        #expect(service.isAllowed(for: example))
        #expect(!service.isAllowed(for: other))

        // A per-site block beats the permissive default.
        store.blockJavaScriptByDefault = false
        service.setRule(host: "other.org", allowed: false)
        #expect(!service.isAllowed(for: other))

        service.removeRule(host: "other.org")
        #expect(service.isAllowed(for: other))
        #expect(service.rule(for: other) == nil)
    }

    @Test func subdomainsInheritTheRegistrableDomainRule() throws {
        let service = try makeService()
        let store = SettingsStore.shared
        let baseline = store.blockJavaScriptByDefault
        defer { store.blockJavaScriptByDefault = baseline }
        store.blockJavaScriptByDefault = false

        service.setRule(host: "news.example.com", allowed: false)

        #expect(service.sortedRules.map(\.host) == ["example.com"])
        for address in ["https://example.com", "https://news.example.com", "https://a.b.example.com/x"] {
            let url = try #require(URL(string: address))
            #expect(!service.isAllowed(for: url), "expected \(address) to be blocked")
        }
    }
}
