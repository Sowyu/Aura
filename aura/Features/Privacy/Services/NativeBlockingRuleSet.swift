import Foundation

/// The network rules Safari's content blocking format cannot express, re-parsed
/// from the original filter lists and handed to the injected bundle.
///
/// `ContentBlockerCompileService` already turns each list into `WKContentRuleList`
/// JSON plus AdGuard "advanced" text. Neither covers `$removeparam`, `$redirect`,
/// or the network rules the converter drops, so those are picked up here from the
/// same raw text and matched inside the WebContent process instead.
struct NativeBlockingRuleSet {
    struct Rule {
        enum Kind: Int {
            case block = 0
            case allow = 1
            case removeParam = 2
            case redirect = 3
        }

        var kind: Kind = .block
        /// `||host^` anchor. Rules with one are bucketed by host, the rest are scanned.
        var host: String?
        var pattern: String = ""
        var leftAnchor = false
        var rightAnchor = false
        var types: UInt32 = 0
        /// 0 any, 1 third-party only, 2 first-party only.
        var party: Int = 0
        var important = false
        var domains: [String] = []
        var excludedDomains: [String] = []
        /// `$removeparam` names. A single empty string means "drop every parameter".
        var parameters: [String] = []
        var redirect = ""
        var redirectOnlyWhenBlocked = false
    }

    struct Stats: Equatable {
        var block = 0
        var allow = 0
        var removeParam = 0
        var redirect = 0
        /// Lines that carry a modifier neither WebKit nor this matcher can honour.
        var skipped = 0

        var total: Int { block + allow + removeParam + redirect }

        mutating func count(_ kind: Rule.Kind) {
            switch kind {
            case .block: block += 1
            case .allow: allow += 1
            case .removeParam: removeParam += 1
            case .redirect: redirect += 1
            }
        }
    }

    var rules: [Rule] = []
    var allowlist: [String] = []
    var stats = Stats()

    // MARK: - Building

    /// Parses raw filter-list text, keeping only the rules the converter drops.
    static func make(fromFilterLines lines: [String], allowlist: [String] = []) -> NativeBlockingRuleSet {
        var set = NativeBlockingRuleSet()
        set.allowlist = allowlist.map { $0.lowercased() }

        for line in lines {
            set.take(NativeBlockingRuleParser.parse(line: line))
        }
        return set
    }

    private mutating func take(_ outcome: NativeBlockingRuleParser.Outcome) {
        switch outcome {
        case let .rule(rule):
            rules.append(rule)
            stats.count(rule.kind)
        case let .allowlistHost(host):
            allowlist.append(host)
        case .unsupported:
            stats.skipped += 1
        case .ignored:
            break
        }
    }

    // MARK: - Serialising

    /// Compact JSON with one-or-two letter keys. The bundle reads this straight
    /// into C structs, so every key is optional and every value is a plain type.
    func jsonObject(revision: String) -> [String: Any] {
        [
            "v": 1,
            "rev": revision,
            "allow": allowlist,
            "r": rules.map(Self.encode(rule:))
        ]
    }

    func jsonData(revision: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject(revision: revision), options: [.sortedKeys])
    }

    // A flat "omit the default" encoder. Splitting it would only scatter the schema.
    // swiftlint:disable:next cyclomatic_complexity
    private static func encode(rule: Rule) -> [String: Any] {
        var encoded: [String: Any] = ["k": rule.kind.rawValue]
        if let host = rule.host, !host.isEmpty { encoded["h"] = host }
        if !rule.pattern.isEmpty { encoded["p"] = rule.pattern }
        if rule.leftAnchor { encoded["la"] = 1 }
        if rule.rightAnchor { encoded["ra"] = 1 }
        if rule.types != 0 { encoded["t"] = rule.types }
        if rule.party != 0 { encoded["tp"] = rule.party }
        if rule.important { encoded["i"] = 1 }
        if !rule.domains.isEmpty { encoded["d"] = rule.domains }
        if !rule.excludedDomains.isEmpty { encoded["x"] = rule.excludedDomains }
        if !rule.parameters.isEmpty { encoded["pm"] = rule.parameters }
        if !rule.redirect.isEmpty { encoded["rd"] = rule.redirect }
        if rule.redirectOnlyWhenBlocked { encoded["rr"] = 1 }
        return encoded
    }
}
