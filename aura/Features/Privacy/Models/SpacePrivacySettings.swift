import Foundation

/// A space's privacy defaults. Ad and tracker blocking is uBlock Origin Lite's job,
/// so nothing here describes filter lists; the fields that survive are the ones
/// no extension can do from inside a page.
struct SpacePrivacySettings: Codable, Equatable, Hashable {
    var blockThirdPartyTrackers: Bool
    var blockFingerprinting: Bool
    /// Global Privacy Control: `Sec-GPC: 1` on page requests plus
    /// `navigator.globalPrivacyControl`. On by default, as the spec allows for a
    /// browser with a stated privacy focus, which one that ships uBlock Origin has.
    var globalPrivacyControl: Bool
    var cookiesPolicy: CookiesPolicy

    init(
        blockThirdPartyTrackers: Bool = false,
        blockFingerprinting: Bool = true,
        globalPrivacyControl: Bool = true,
        cookiesPolicy: CookiesPolicy = .allowAll
    ) {
        self.blockThirdPartyTrackers = blockThirdPartyTrackers
        self.blockFingerprinting = blockFingerprinting
        self.globalPrivacyControl = globalPrivacyControl
        self.cookiesPolicy = cookiesPolicy
    }

    enum CodingKeys: String, CodingKey {
        case blockThirdPartyTrackers
        case blockFingerprinting
        case globalPrivacyControl
        case cookiesPolicy
    }

    /// Hand-written so a blob saved before uBlock Origin took over blocking, which
    /// still carries `adBlock`/`adBlocking`, decodes instead of throwing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockThirdPartyTrackers = try container.decodeIfPresent(Bool.self, forKey: .blockThirdPartyTrackers) ?? false
        blockFingerprinting = try container.decodeIfPresent(Bool.self, forKey: .blockFingerprinting) ?? true
        globalPrivacyControl = try container.decodeIfPresent(Bool.self, forKey: .globalPrivacyControl) ?? true
        cookiesPolicy = try container.decodeIfPresent(CookiesPolicy.self, forKey: .cookiesPolicy) ?? .allowAll
    }
}
