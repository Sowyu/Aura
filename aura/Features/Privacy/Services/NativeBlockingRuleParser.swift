import Foundation

/// ABP network-rule parser, scoped to the rules Safari content blocking drops.
///
/// Everything the converter already handles comes back as `.ignored` so it is not
/// matched twice. Rules that need a modifier neither WebKit nor the injected
/// bundle can honour come back as `.unsupported`, which is what the recovered-vs-
/// dropped counts are built from.
enum NativeBlockingRuleParser {
    enum Outcome {
        case rule(NativeBlockingRuleSet.Rule)
        /// `@@||host^$document`: switches the whole site off rather than one request.
        case allowlistHost(String)
        case unsupported
        case ignored
    }

    /// Types WebKit's content blocking format has no equivalent for, so a rule
    /// restricted to one of them never made it into the compiled rule list.
    private static let webKitUnsupportedTypes: UInt32 =
        AuraResourceType.webSocket.rawValue | AuraResourceType.ping.rawValue | AuraResourceType.other.rawValue

    private static let typeMasks: [String: UInt32] = [
        "script": AuraResourceType.script.rawValue,
        "image": AuraResourceType.image.rawValue,
        "stylesheet": AuraResourceType.stylesheet.rawValue,
        "css": AuraResourceType.stylesheet.rawValue,
        "xmlhttprequest": AuraResourceType.XHR.rawValue,
        "xhr": AuraResourceType.XHR.rawValue,
        "subdocument": AuraResourceType.subdocument.rawValue,
        "frame": AuraResourceType.subdocument.rawValue,
        "media": AuraResourceType.media.rawValue,
        "font": AuraResourceType.font.rawValue,
        "websocket": AuraResourceType.webSocket.rawValue,
        "ping": AuraResourceType.ping.rawValue,
        "beacon": AuraResourceType.ping.rawValue,
        "other": AuraResourceType.other.rawValue,
        "object": AuraResourceType.other.rawValue,
        "document": AuraResourceType.document.rawValue,
        "doc": AuraResourceType.document.rawValue
    ]

    static func parse(line rawLine: String) -> Outcome {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !line.hasPrefix("#") else {
            return .ignored
        }
        guard !isCosmetic(line) else { return .ignored }

        var body = line
        let isException = body.hasPrefix("@@")
        if isException { body = String(body.dropFirst(2)) }

        let (patternText, modifierText) = split(body: body)
        guard !isRegex(patternText) else { return .unsupported }

        var options = Options()
        guard options.apply(modifierText) else { return .unsupported }

        if isException, options.types == AuraResourceType.document.rawValue,
           let host = anchoredHost(in: patternText), isBareHostPattern(patternText, host: host)
        {
            return .allowlistHost(host)
        }

        guard !options.handledElsewhere else { return .ignored }
        guard isException || options.needsNativeMatching else { return .ignored }
        return build(pattern: patternText, options: options, isException: isException)
    }

    // MARK: - Pieces

    private static func isCosmetic(_ line: String) -> Bool {
        for marker in ["##", "#@#", "#%#", "#?#", "#$#", "#@$#", "#@?#", "$$", "$@$"]
            where line.contains(marker)
        {
            return true
        }
        return false
    }

    private static func isRegex(_ pattern: String) -> Bool {
        pattern.count > 2 && pattern.hasPrefix("/") && pattern.hasSuffix("/")
    }

    /// Splits at the first `$` outside a leading `/regex/`, matching how
    /// `RemoveParamRuleSet` reads the same lines.
    private static func split(body: String) -> (pattern: String, modifiers: String) {
        var insideRegex = false
        var previous: Character?
        var index = body.startIndex

        while index < body.endIndex {
            let character = body[index]
            if character == "/", previous != "\\", body.first == "/" { insideRegex.toggle() }
            if character == "$", !insideRegex, previous != "\\" {
                return (String(body[body.startIndex..<index]), String(body[body.index(after: index)...]))
            }
            previous = character
            index = body.index(after: index)
        }
        return (body, "")
    }

    private static func anchoredHost(in pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        let rest = pattern.dropFirst(2)
        let host = rest.prefix { $0 != "/" && $0 != "^" && $0 != "|" && $0 != "*" && $0 != "?" }
        guard !host.isEmpty, !host.contains("*") else { return nil }
        return String(host).lowercased()
    }

    private static func isBareHostPattern(_ pattern: String, host: String) -> Bool {
        let tail = pattern.dropFirst(2 + host.count)
        return tail.isEmpty || tail == "^" || tail == "^|"
    }

    private static func build(pattern: String, options: Options, isException: Bool) -> Outcome {
        var rule = NativeBlockingRuleSet.Rule()
        rule.types = options.types
        rule.party = options.party
        rule.important = options.important
        rule.domains = options.domains
        rule.excludedDomains = options.excludedDomains

        if isException {
            rule.kind = .allow
        } else if let parameters = options.removeParams {
            rule.kind = .removeParam
            rule.parameters = parameters
        } else if let redirect = options.redirect {
            rule.kind = .redirect
            rule.redirect = redirect
            rule.redirectOnlyWhenBlocked = options.redirectOnlyWhenBlocked
        }

        var body = pattern
        if let host = anchoredHost(in: body) {
            rule.host = host
            body = String(body.dropFirst(2 + host.count))
        } else if body.hasPrefix("||") {
            // A wildcard inside the host is not expressible without regex.
            return .unsupported
        } else if body.hasPrefix("|") {
            rule.leftAnchor = true
            body = String(body.dropFirst())
        }

        if body.hasSuffix("|"), !body.hasSuffix("\\|") {
            rule.rightAnchor = true
            body = String(body.dropLast())
        }
        while body.hasPrefix("*") { body = String(body.dropFirst()) }
        rule.pattern = body

        guard rule.host != nil || !rule.pattern.isEmpty || !rule.parameters.isEmpty else { return .unsupported }
        return .rule(rule)
    }
}

extension NativeBlockingRuleParser {
    /// The `$…` modifier list, reduced to what the matcher acts on.
    struct Options {
        var types: UInt32 = 0
        var party = 0
        var important = false
        var domains: [String] = []
        var excludedDomains: [String] = []
        var removeParams: [String]?
        var redirect: String?
        var redirectOnlyWhenBlocked = false
        /// True when a named type has no equivalent in Safari's rule format, so the
        /// converter cannot have compiled this rule.
        var namesUnsupportedType = false
        /// True when another layer already owns this rule. Counting it as dropped
        /// would make the recovery numbers meaningless.
        var handledElsewhere = false

        var needsNativeMatching: Bool {
            removeParams != nil || redirect != nil || namesUnsupportedType
        }

        /// Returns false when the rule carries a modifier nothing here can honour.
        mutating func apply(_ text: String) -> Bool {
            var included: UInt32 = 0
            var excluded: UInt32 = 0

            for modifier in Self.split(text) {
                let inverted = modifier.hasPrefix("~")
                let body = inverted ? String(modifier.dropFirst()) : modifier
                let name = body.prefix { $0 != "=" }.lowercased()
                let value = body.dropFirst(name.count).dropFirst()

                if let mask = NativeBlockingRuleParser.typeMask(for: name) {
                    if inverted {
                        excluded |= mask
                    } else {
                        included |= mask
                        namesUnsupportedType = namesUnsupportedType
                            || NativeBlockingRuleParser.isUnsupportedByWebKit(mask)
                    }
                    continue
                }
                guard apply(name: name, value: String(value), inverted: inverted) else { return false }
            }

            if included != 0 {
                types = included
            } else if excluded != 0 {
                types = AuraResourceType.any.rawValue & ~excluded
            }
            return true
        }

        /// Modifiers another layer already owns: popups go through the converter, the
        /// `hide` family through `AdvancedBlockingService`.
        private static let otherLayers: Set<String> = [
            "popup", "popunder", "elemhide", "ehide", "generichide", "ghide",
            "specifichide", "shide", "genericblock"
        ]

        private mutating func apply(name: String, value: String, inverted: Bool) -> Bool {
            if Self.otherLayers.contains(name) {
                handledElsewhere = true
                return true
            }
            switch name {
            case "third-party", "3p":
                party = inverted ? 2 : 1
            case "first-party", "1p":
                party = inverted ? 1 : 2
            case "important":
                important = true
            case "match-case", "all", "":
                break
            case "domain", "from":
                applyDomains(value)
            case "removeparam", "queryprune":
                return applyRemoveParam(value)
            case "empty":
                redirect = "nooptext"
            case "redirect", "redirect-rule", "rewrite":
                return applyRedirect(name: name, value: value)
            default:
                return false
            }
            return true
        }

        /// "Keep everything except X" and regex parameter names both need whole-query
        /// rewriting, which is not worth the risk of mangling a URL.
        private mutating func applyRemoveParam(_ value: String) -> Bool {
            guard !value.hasPrefix("~"), !value.hasPrefix("/") else { return false }
            removeParams = [value]
            return true
        }

        private mutating func applyRedirect(name: String, value: String) -> Bool {
            var resource = value
            if resource.hasPrefix("abp-resource:") { resource = String(resource.dropFirst(13)) }
            resource = Self.strippingPriority(from: resource)
            guard !resource.isEmpty else { return false }
            redirect = resource
            redirectOnlyWhenBlocked = name == "redirect-rule"
            return true
        }

        /// uBO appends a priority as `name:5`. It only orders competing redirects.
        private static func strippingPriority(from resource: String) -> String {
            guard let colon = resource.lastIndex(of: ":"), colon != resource.startIndex else { return resource }
            let suffix = resource[resource.index(after: colon)...]
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return resource }
            return String(resource[resource.startIndex..<colon])
        }

        private mutating func applyDomains(_ value: String) {
            for entry in value.split(whereSeparator: { $0 == "|" || $0 == "," }) {
                let lowered = entry.lowercased()
                if lowered.hasPrefix("~") {
                    excludedDomains.append(String(lowered.dropFirst()))
                } else {
                    domains.append(lowered)
                }
            }
        }

        /// Comma-split that leaves commas inside a `/regex/` value alone. Only a `/`
        /// straight after the `=` opens a regex, so `redirect=a.com/b.js,important`
        /// still splits into two modifiers.
        private static func split(_ text: String) -> [String] {
            var parts: [String] = []
            var current = ""
            var insideRegex = false
            var atValueStart = false
            var previous: Character?

            for character in text {
                if character == "/", previous != "\\" {
                    if atValueStart {
                        insideRegex = true
                    } else if insideRegex {
                        insideRegex = false
                    }
                }
                atValueStart = character == "=" && !insideRegex
                if character == ",", !insideRegex {
                    parts.append(current)
                    current = ""
                    previous = character
                    continue
                }
                current.append(character)
                previous = character
            }
            parts.append(current)
            return parts.filter { !$0.isEmpty }
        }
    }

    fileprivate static func typeMask(for name: String) -> UInt32? {
        typeMasks[name]
    }

    fileprivate static func isUnsupportedByWebKit(_ mask: UInt32) -> Bool {
        mask & webKitUnsupportedTypes != 0
    }
}
