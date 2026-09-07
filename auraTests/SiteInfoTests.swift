import Foundation
@testable import Aura
import Testing

/// The reducer behind the address bar's site panel. Pure, so every row the panel can
/// show is checked without a window or a live page.
struct SiteInfoSummaryTests {
    private func summary(
        _ address: String,
        globalPrivacyControl: Bool = true,
        javaScriptRule: Bool? = nil,
        blocksByDefault: Bool = false,
        permissions: SitePermissionSettings? = nil,
        zoom: Double = 1,
        spaceName: String? = nil
    ) -> SiteInfoSummary? {
        guard let url = URL(string: address) else { return nil }
        return SiteInfoSummary(
            url: url,
            globalPrivacyControl: globalPrivacyControl,
            javaScriptRule: javaScriptRule,
            blocksJavaScriptByDefault: blocksByDefault,
            permissions: permissions,
            zoom: zoom,
            spaceName: spaceName
        )
    }

    @Test func theHostIsTheRegistrableDomainAndTheOriginIsWhatTheUserSees() throws {
        let info = try #require(summary("https://news.bbc.co.uk/sport?live=1"))
        #expect(info.host == "bbc.co.uk")
        #expect(info.origin == "https://news.bbc.co.uk")
        #expect(info.isSecure)
        #expect(info.connectionSummary == "Connection is encrypted")
    }

    @Test func plainHTTPIsReportedAsUnencryptedAndKeepsItsPort() throws {
        let info = try #require(summary("http://example.com:8080/app"))
        #expect(!info.isSecure)
        #expect(info.origin == "http://example.com:8080")
        #expect(info.connectionSummary == "Connection is not encrypted")
    }

    @Test func pagesWithNoSiteHaveNoPanel() {
        // Aura's own pages parse with a host ("home"), which is not a site anyone can
        // grant anything to.
        #expect(summary("aura://home") == nil)
        #expect(summary("ora://settings") == nil)
        #expect(summary("about:blank") == nil)
        #expect(summary("data:text/html,hello") == nil)
    }

    @Test func javaScriptFollowsTheGlobalDefaultUntilTheSiteHasARule() throws {
        var info = try #require(summary("https://example.com", blocksByDefault: false))
        #expect(info.javaScriptAllowed)
        #expect(info.javaScriptRule == nil)

        info = try #require(summary("https://example.com", blocksByDefault: true))
        #expect(!info.javaScriptAllowed)

        info = try #require(summary("https://example.com", javaScriptRule: true, blocksByDefault: true))
        #expect(info.javaScriptAllowed)
        #expect(info.javaScriptRule == true)
    }

    @Test func grantsAreReadOffTheStoredEntry() throws {
        let info = try #require(
            summary(
                "https://example.com",
                permissions: SitePermissionSettings(host: "example.com", camera: true, microphone: false)
            )
        )
        #expect(info.camera == true)
        #expect(info.microphone == false)
        #expect(SiteInfoSummary.permissionLabel(info.camera) == "Allowed")
        #expect(SiteInfoSummary.permissionLabel(info.microphone) == "Blocked")
        #expect(SiteInfoSummary.permissionLabel(nil) == "Ask")
    }

    @Test func zoomIsLabelledAndClamped() throws {
        var info = try #require(summary("https://example.com", zoom: 1.5))
        #expect(info.zoomLabel == "150%")

        info = try #require(summary("https://example.com", zoom: 42))
        #expect(info.zoom == SiteZoom.maximum)
        #expect(info.zoomLabel == "300%")
    }

    @Test func globalPrivacyControlIsLabelledTheWayFirefoxDoes() throws {
        #expect(try #require(summary("https://example.com")).globalPrivacyControlLabel == "Applied")
        #expect(try #require(summary("https://example.com", globalPrivacyControl: false))
            .globalPrivacyControlLabel == "Off")
    }

    @Test func theSpaceRuleOnlyShowsWhenOneExists() throws {
        #expect(try #require(summary("https://example.com")).spaceName == nil)
        #expect(try #require(summary("https://example.com", spaceName: "Work")).spaceName == "Work")
    }
}
