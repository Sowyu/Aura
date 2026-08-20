import Foundation

/// `$removeparam` rules, which SafariConverterLib drops outright: WebKit content
/// blocking cannot rewrite a URL and the converter does not even parse the modifier.
///
/// Aura applies them at `decidePolicyFor` by cancelling the navigation and re-issuing
/// it with the tracking parameters gone.
///
/// ponytail: document navigations only, because `decidePolicyFor` is the only URL
/// rewrite hook WKWebView gives us. Subresource requests keep their parameters.
/// Revisit if WebKit ever ships a blocking request API.
struct RemoveParamRuleSet {
    /// One `$removeparam` rule, reduced to the parts we can act on.
    struct Rule {
        /// Registrable-ish host the rule is scoped to, empty for a generic rule.
        let domains: [String]
        /// Parameter name to drop. `nil` together with a `nil` pattern means "drop them all".
        let name: String?
        /// `/regex/` form of the parameter name.
        let pattern: NSRegularExpression?
        let isException: Bool
    }

    private let rules: [Rule]
    private let exceptions: [Rule]

    /// Rules that apply to every host, indexed by parameter name for the common case.
    private let genericNames: Set<String>
    private let genericPatterns: [Rule]
    private let genericDropsEverything: Bool
    private let domainScoped: [String: [Rule]]

    var ruleCount: Int { rules.count + exceptions.count }
    var isEmpty: Bool { rules.isEmpty }

    init(lines: [String]) {
        let parsed = lines.compactMap(Self.parse(line:))
        rules = parsed.filter { !$0.isException }
        exceptions = parsed.filter(\.isException)

        var names: Set<String> = []
        var patterns: [Rule] = []
        var dropsEverything = false
        var scoped: [String: [Rule]] = [:]

        for rule in rules {
            guard rule.domains.isEmpty else {
                for domain in rule.domains {
                    scoped[domain, default: []].append(rule)
                }
                continue
            }

            if let name = rule.name {
                names.insert(name)
            } else if rule.pattern != nil {
                patterns.append(rule)
            } else {
                dropsEverything = true
            }
        }

        genericNames = names
        genericPatterns = patterns
        genericDropsEverything = dropsEverything
        domainScoped = scoped
    }

    /// The URL with tracking parameters stripped, or nil when nothing changes.
    func strippedURL(for url: URL) -> URL? {
        guard !rules.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else {
            return nil
        }

        let host = (url.host ?? "").lowercased()
        let scoped = matchingScopedRules(host: host)
        guard genericDropsEverything || !genericNames.isEmpty || !genericPatterns.isEmpty || !scoped.isEmpty else {
            return nil
        }

        let kept = queryItems.filter { !shouldRemove($0.name, host: host, scoped: scoped) }
        guard kept.count != queryItems.count else { return nil }

        components.queryItems = kept.isEmpty ? nil : kept
        // An empty query still leaves a bare "?" behind unless it is cleared explicitly.
        if kept.isEmpty {
            components.percentEncodedQuery = nil
        }
        return components.url
    }

    private func matchingScopedRules(host: String) -> [Rule] {
        guard !host.isEmpty, !domainScoped.isEmpty else { return [] }

        var matches: [Rule] = []
        for (domain, domainRules) in domainScoped where host == domain || host.hasSuffix("." + domain) {
            matches.append(contentsOf: domainRules)
        }
        return matches
    }

    private func shouldRemove(_ parameter: String, host: String, scoped: [Rule]) -> Bool {
        let matched = genericDropsEverything
            || genericNames.contains(parameter)
            || genericPatterns.contains { $0.matches(parameter) }
            || scoped.contains { $0.matches(parameter) }

        guard matched else { return false }
        return !exceptions.contains { $0.applies(to: host) && $0.matches(parameter) }
    }

    // MARK: - Parsing

    // swiftlint:disable:next cyclomatic_complexity
    private static func parse(line rawLine: String) -> Rule? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), line.contains("removeparam") else {
            return nil
        }
        // Cosmetic rules can mention the word in a selector; only basic rules carry modifiers.
        guard !line.contains("##"), !line.contains("#@#"), !line.contains("#%#"), !line.contains("#?#") else {
            return nil
        }

        var body = line
        let isException = body.hasPrefix("@@")
        if isException {
            body = String(body.dropFirst(2))
        }

        guard let separator = modifierSeparatorIndex(in: body) else { return nil }
        let pattern = String(body[body.startIndex..<separator])
        let modifiers = splitModifiers(String(body[body.index(after: separator)...]))

        guard let removeParam = modifiers.first(where: { $0 == "removeparam" || $0.hasPrefix("removeparam=") })
        else {
            return nil
        }

        let value = removeParam.hasPrefix("removeparam=")
            ? String(removeParam.dropFirst("removeparam=".count))
            : ""
        // "remove everything except X" needs whole-query rewriting; not worth the risk.
        guard !value.hasPrefix("~") else { return nil }

        var domains = domainsFromPattern(pattern)
        if domains == nil { return nil }
        for modifier in modifiers where modifier.hasPrefix("domain=") || modifier.hasPrefix("from=") {
            let listed = modifier.drop { $0 != "=" }.dropFirst().split(separator: "|").map(String.init)
            // Mixing allowed and disallowed domains is not expressible here.
            guard !listed.contains(where: { $0.hasPrefix("~") }) else { return nil }
            domains = (domains ?? []) + listed.map { $0.lowercased() }
        }

        if value.hasPrefix("/"), value.hasSuffix("/"), value.count > 2 {
            let expression = String(value.dropFirst().dropLast())
            guard let regex = try? NSRegularExpression(pattern: expression) else { return nil }
            return Rule(domains: domains ?? [], name: nil, pattern: regex, isException: isException)
        }

        return Rule(
            domains: domains ?? [],
            name: value.isEmpty ? nil : value,
            pattern: nil,
            isException: isException
        )
    }

    /// Index of the `$` that starts the modifier list, skipping any inside a `/regex/` pattern.
    private static func modifierSeparatorIndex(in body: String) -> String.Index? {
        var insideRegex = false
        var index = body.startIndex
        var previous: Character?

        while index < body.endIndex {
            let character = body[index]
            if character == "/", previous != "\\", body.first == "/" {
                insideRegex.toggle()
            }
            if character == "$", !insideRegex {
                return index
            }
            previous = character
            index = body.index(after: index)
        }
        return nil
    }

    private static func splitModifiers(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var insideRegex = false
        var previous: Character?

        for character in text {
            if character == "/", previous != "\\" {
                insideRegex.toggle()
            }
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

    /// Host scope for a rule pattern, or nil when the pattern targets something we
    /// cannot judge (a path, a regex, a subresource URL).
    private static func domainsFromPattern(_ pattern: String) -> [String]? {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "*" { return [] }
        guard trimmed.hasPrefix("||") else { return nil }

        var host = String(trimmed.dropFirst(2))
        while let last = host.last, last == "^" || last == "|" || last == "/" {
            host.removeLast()
        }
        // A path or query in the pattern means the rule targets a subresource.
        guard !host.isEmpty, !host.contains("/"), !host.contains("?"), !host.contains("*") else { return nil }
        return [host.lowercased()]
    }
}

private extension RemoveParamRuleSet.Rule {
    func matches(_ parameter: String) -> Bool {
        if let name { return name == parameter }
        if let pattern {
            let range = NSRange(parameter.startIndex..<parameter.endIndex, in: parameter)
            return pattern.firstMatch(in: parameter, range: range) != nil
        }
        return true
    }

    func applies(to host: String) -> Bool {
        guard !domains.isEmpty else { return true }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
