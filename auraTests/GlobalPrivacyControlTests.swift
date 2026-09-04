import Foundation
@testable import Aura
import Testing

/// The two halves of the Global Privacy Control signal, as pure functions: the header
/// rule a navigation goes through, and the user script that sets the page-side flag.
struct GlobalPrivacyControlTests {
    private let signalOn = SpacePrivacySettings(globalPrivacyControl: true)
    private let signalOff = SpacePrivacySettings(globalPrivacyControl: false)

    private func signalled(
        _ address: String,
        method: String = "GET",
        settings: SpacePrivacySettings? = nil,
        isMainFrame: Bool = true,
        isBackForward: Bool = false,
        headers: [String: String] = [:]
    ) -> URLRequest? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return BrowserPrivacyService.requestSignallingGlobalPrivacyControl(
            request,
            privacySettings: settings ?? signalOn,
            isMainFrame: isMainFrame,
            isBackForward: isBackForward
        )
    }

    @Test func aDocumentRequestGetsTheHeader() throws {
        let request = try #require(signalled("https://example.com/page"))
        #expect(request.value(forHTTPHeaderField: "Sec-GPC") == "1")
        #expect(request.url?.absoluteString == "https://example.com/page")
        #expect(signalled("http://example.com")?.value(forHTTPHeaderField: "Sec-GPC") == "1")
    }

    @Test func theReissuedRequestPassesStraightThrough() {
        // The one guard against cancelling forever: a request that already carries the
        // header is left alone, whichever way the field name is cased.
        #expect(signalled("https://example.com", headers: ["Sec-GPC": "1"]) == nil)
        #expect(signalled("https://example.com", headers: ["sec-gpc": "1"]) == nil)
    }

    @Test func nothingIsAddedWhenTheSignalIsOff() {
        #expect(signalled("https://example.com", settings: signalOff) == nil)
    }

    @Test func onlyMainFrameGetsOverHTTPAreReissued() {
        // A POST cannot be re-issued: its body never reaches the UI process.
        #expect(signalled("https://example.com", method: "POST") == nil)
        // A subframe re-issued through the web view would replace the whole page.
        #expect(signalled("https://example.com", isMainFrame: false) == nil)
        // A back/forward step re-issued as a load would push a new history entry.
        #expect(signalled("https://example.com", isBackForward: true) == nil)
        // Aura's own pages and extension pages have no server to signal to.
        #expect(signalled("aura://home") == nil)
        #expect(signalled("webkit-extension://abc/popup.html") == nil)
        #expect(signalled("file:///tmp/page.html") == nil)
    }

    @Test func theScriptFollowsTheSetting() {
        let names = { (settings: SpacePrivacySettings) in
            BrowserPrivacyService.privacyScripts(for: settings).compactMap(\.name)
        }
        #expect(names(signalOn).contains("ora-global-privacy-control"))
        #expect(!names(signalOff).contains("ora-global-privacy-control"))
        // Fingerprinting protection is a separate switch and must not ride along.
        #expect(names(SpacePrivacySettings(blockFingerprinting: false, globalPrivacyControl: true))
            == ["ora-global-privacy-control"])

        let script = BrowserPrivacyService.globalPrivacyControlScriptSource
        #expect(script.contains("'globalPrivacyControl'"))
        #expect(script.contains("Navigator.prototype"))
        #expect(script.contains("return true"))
    }

    @Test func aBlobSavedBeforeTheSignalExistedDecodesWithItOn() throws {
        let legacy = Data(#"{"blockThirdPartyTrackers":false,"blockFingerprinting":true,"cookiesPolicy":"Allow all"}"#
            .utf8)
        #expect(try JSONDecoder().decode(SpacePrivacySettings.self, from: legacy).globalPrivacyControl)

        let encoded = try JSONEncoder().encode(signalOff)
        #expect(!(try JSONDecoder().decode(SpacePrivacySettings.self, from: encoded)).globalPrivacyControl)
    }
}
