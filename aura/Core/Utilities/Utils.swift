import Foundation
import PublicSuffixList

func extractDomainOrIP(from text: String) -> String? {
    let hasScheme = text.hasPrefix("http://") || text.hasPrefix("https://")
    guard let url = URL(string: hasScheme ? text : "https://\(text)") else {
        return nil
    }

    guard let host = url.host else {
        return nil
    }

    return host
}

/// eTLD+1 for permission-style rules, so a decision made on `news.example.com`
/// also covers `example.com` and its other subdomains.
func registrableDomain(from host: String) -> String {
    let normalized = host
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))

    // IPv4/IPv6 literals and single-label hosts such as `localhost` have no parent domain.
    guard !normalized.isEmpty, !normalized.contains(":") else { return normalized }
    if normalized.range(of: #"^(\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil {
        return normalized
    }

    // Public Suffix List, so "news.bbc.co.uk" -> "bbc.co.uk", not "co.uk".
    let labels = normalized.split(separator: ".")
    guard let suffix = PublicSuffixList.parsePublicSuffix(normalized)?.suffix, suffix != normalized else {
        return labels.count > 2 ? labels.suffix(2).joined(separator: ".") : normalized
    }
    let suffixCount = suffix.split(separator: ".").count
    return labels.suffix(suffixCount + 1).joined(separator: ".")
}

/// Registrable domain for a URL, or nil when the URL has no host (`about:blank`, data URLs).
func registrableDomain(from url: URL) -> String? {
    guard let host = url.host, !host.isEmpty else { return nil }
    let domain = registrableDomain(from: host)
    return domain.isEmpty ? nil : domain
}

/// `[::1]`, `[::1]:3000`, `[2001:db8::1]/path` and the scheme-prefixed forms.
private func isIPv6Literal(_ text: String) -> Bool {
    var host = text
    if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
    return host.hasPrefix("[") && host.contains("]") && host.contains(":")
}

func isValidURL(_ text: String) -> Bool {
    if oraInternalURL(from: text) != nil { return true }
    if isIPv6Literal(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return true }

    guard let host = extractDomainOrIP(from: text) else { return false }

    if host == "localhost" {
        return true
    }

    let ipPattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
    if host.range(of: ipPattern, options: .regularExpression) != nil {
        return true
    }

    let domainPattern =
        #"^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$"#

    return host.range(of: domainPattern, options: .regularExpression) != nil
}

/// Internal `aura://` addresses are URLs, not search queries. Legacy `ora://` input
/// is accepted and handed back in canonical form.
func oraInternalURL(from text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.isOraInternal, url.host != nil else { return nil }
    return url.canonicalOraInternal
}

func constructURL(from text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let internalURL = oraInternalURL(from: trimmed) {
        return internalURL
    }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return URL(string: trimmed)
    }
    guard isValidURL(trimmed) else { return nil }
    let host = extractDomainOrIP(from: trimmed) ?? ""
    // Loopback and link-local dev servers are plain http; everything else defaults to https.
    let isLoopback = host == "localhost" || host.hasPrefix("127.") || host == "0.0.0.0"
        || trimmed.hasPrefix("[::1]") || host.hasSuffix(".localhost")
    let scheme = isLoopback ? "http" : "https"
    return URL(string: "\(scheme)://\(trimmed)")
}
