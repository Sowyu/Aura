import Foundation

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

func isValidURL(_ text: String) -> Bool {
    if oraInternalURL(from: text) != nil { return true }

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

/// Internal `ora://` addresses are URLs, not search queries.
func oraInternalURL(from text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.isOraInternal, url.host != nil else { return nil }
    return url
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
    let host = extractDomainOrIP(from: trimmed)
    let scheme = (host == "localhost") ? "http" : "https"
    return URL(string: "\(scheme)://\(trimmed)")
}
