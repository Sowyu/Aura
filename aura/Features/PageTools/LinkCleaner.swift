import Foundation

/// Strips the click-tracking parameters campaign tooling appends to shared links, so
/// "Copy Link With Clean Parameters" hands over the address the site would serve on its
/// own.
///
/// The work happens on `percentEncodedQueryItems` rather than the decoded ones: reading
/// `queryItems` and writing them back re-encodes every value, which turns a literal
/// `%2B` in a signed URL into `+` and breaks the signature. Nothing here decodes, so a
/// link with no tracking on it comes back byte-identical.
enum LinkCleaner {
    /// Exact parameter names, matched case-insensitively.
    static let trackedNames: Set<String> = [
        "fbclid", "gclid", "mc_cid", "mc_eid", "ref_src", "igshid"
    ]

    /// Prefixes, for the families whose member list is open ended.
    static let trackedPrefixes = ["utm_"]

    static func isTracking(_ name: String) -> Bool {
        let lower = name.lowercased()
        if trackedNames.contains(lower) { return true }
        return trackedPrefixes.contains { lower.hasPrefix($0) }
    }

    /// `url` without its tracking parameters. Path, fragment and every other parameter
    /// are left exactly as they were.
    static func clean(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems,
              !items.isEmpty
        else { return url }

        let kept = items.filter { !isTracking($0.name) }
        guard kept.count != items.count else { return url }
        // An empty array still writes a trailing "?", so the whole query goes instead.
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }
}
