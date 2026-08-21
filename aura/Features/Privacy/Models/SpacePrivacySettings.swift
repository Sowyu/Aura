import Foundation

/// A space's privacy defaults. Ad and tracker blocking is uBlock Origin's job,
/// so nothing here describes filter lists; the fields that survive are the ones
/// no extension can do from inside a page.
struct SpacePrivacySettings: Codable, Equatable, Hashable {
    var blockThirdPartyTrackers: Bool
    var blockFingerprinting: Bool
    var cookiesPolicy: CookiesPolicy

    init(
        blockThirdPartyTrackers: Bool = false,
        blockFingerprinting: Bool = true,
        cookiesPolicy: CookiesPolicy = .allowAll
    ) {
        self.blockThirdPartyTrackers = blockThirdPartyTrackers
        self.blockFingerprinting = blockFingerprinting
        self.cookiesPolicy = cookiesPolicy
    }

    enum CodingKeys: String, CodingKey {
        case blockThirdPartyTrackers
        case blockFingerprinting
        case cookiesPolicy
    }

    /// Hand-written so a blob saved before uBlock Origin took over blocking, which
    /// still carries `adBlock`/`adBlocking`, decodes instead of throwing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockThirdPartyTrackers = try container.decodeIfPresent(Bool.self, forKey: .blockThirdPartyTrackers) ?? false
        blockFingerprinting = try container.decodeIfPresent(Bool.self, forKey: .blockFingerprinting) ?? true
        cookiesPolicy = try container.decodeIfPresent(CookiesPolicy.self, forKey: .cookiesPolicy) ?? .allowAll
    }
}
