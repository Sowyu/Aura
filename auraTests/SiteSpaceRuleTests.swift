import Foundation
@testable import Aura
import SwiftData
import Testing

@MainActor
struct SiteSpaceRuleTests {
    private func makeService() throws -> SiteSpaceRuleService {
        let container = try ModelContainer(
            for: SiteSpaceRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return SiteSpaceRuleService(context: ModelContext(container))
    }

    @Test func aSiteWithoutARuleStaysWhereItIs() throws {
        let service = try makeService()
        let url = try #require(URL(string: "https://example.com/page"))

        #expect(service.containerID(for: url) == nil)
        #expect(service.containerID(forHost: "example.com") == nil)
        #expect(service.sortedRules.isEmpty)
    }

    @Test func subdomainsInheritTheRegistrableDomainRule() throws {
        let service = try makeService()
        let space = UUID()
        service.setRule(host: "news.example.com", containerID: space)

        #expect(service.sortedRules.map(\.host) == ["example.com"])
        for address in ["https://example.com", "https://news.example.com", "https://a.b.example.com/x"] {
            let url = try #require(URL(string: address))
            #expect(service.containerID(for: url) == space, "expected \(address) to route to the space")
        }
    }

    @Test func settingTheSameHostTwiceReplacesTheRule() throws {
        let service = try makeService()
        let first = UUID()
        let second = UUID()

        service.setRule(host: "example.com", containerID: first)
        service.setRule(host: "www.example.com", containerID: second)

        #expect(service.sortedRules.count == 1)
        #expect(service.containerID(forHost: "example.com") == second)
    }

    @Test func rulesCanBeClearedOneSiteOrOneSpaceAtATime() throws {
        let service = try makeService()
        let work = UUID()
        let personal = UUID()

        service.setRule(host: "example.com", containerID: work)
        service.setRule(host: "other.org", containerID: work)
        service.setRule(host: "third.net", containerID: personal)

        service.removeRule(host: "example.com")
        #expect(service.containerID(forHost: "example.com") == nil)
        #expect(service.sortedRules.map(\.host) == ["other.org", "third.net"])

        // Deleting a space must not strand its rules pointing at something that is gone.
        service.removeRules(forContainer: work)
        #expect(service.sortedRules.map(\.host) == ["third.net"])
        #expect(service.containerID(forHost: "third.net") == personal)
    }
}
