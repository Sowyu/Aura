import Foundation

/// Internal pages use the `aura://` scheme (for example `aura://settings/spaces`).
/// They render as native SwiftUI inside a tab and are never handed to WebKit.
extension URL {
    /// A web security origin. Paths and default ports do not distinguish origins;
    /// subdomains, schemes and non-default ports do.
    var webOrigin: String? {
        guard let scheme = scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = host?.lowercased(), !host.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        let defaultPort = scheme == "https" ? 443 : 80
        if let port, port != defaultPort { components.port = port }
        return components.url?.absoluteString
    }

    static let auraScheme = "aura"

    /// Pre-rename scheme. Saved tabs and typed addresses still use it, so it stays
    /// readable forever; anything opened through `auraInternalURL(from:)` comes back
    /// rewritten to `auraScheme`.
    static let legacyOraScheme = "ora"

    var isAuraInternal: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == Self.auraScheme || scheme == Self.legacyOraScheme
    }

    var isAuraSettings: Bool {
        isAuraInternal && host?.lowercased() == "settings"
    }

    /// `aura://home`: the new-tab page, rendered natively like settings.
    var isAuraHome: Bool {
        isAuraInternal && host?.lowercased() == "home"
    }

    /// `aura://extensions`: the add-on store, rendered natively like settings.
    var isAuraExtensions: Bool {
        isAuraInternal && host?.lowercased() == "extensions"
    }

    /// `aura://view-source?url=…`: the page's HTML, rendered natively with line numbers.
    var isAuraViewSource: Bool {
        isAuraInternal && host?.lowercased() == "view-source"
    }

    /// `aura://reader?url=…`: the article text of a page, rendered natively.
    var isAuraReader: Bool {
        isAuraInternal && host?.lowercased() == "reader"
    }

    /// The page a view-source or reader address describes. Reading goes through
    /// `queryItems`, which undoes the escaping `auraPageTool` applied.
    var auraPageToolTarget: URL? {
        guard isAuraViewSource || isAuraReader,
              let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value
        else { return nil }
        return URL(string: raw)
    }

    /// The settings section a `aura://settings/<section>` URL points at, if it names a known one.
    var auraSettingsSection: SettingsTab? {
        guard isAuraSettings else { return nil }
        guard let raw = pathComponents.first(where: { $0 != "/" }) else { return nil }
        return SettingsTab.resolve(rawValue: raw)
    }

    /// `ora://x` rewritten to `aura://x`. Any other URL comes back untouched.
    var canonicalAuraInternal: URL {
        guard scheme?.lowercased() == Self.legacyOraScheme,
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        else { return self }
        components.scheme = Self.auraScheme
        return components.url ?? self
    }

    /// A scheme + host always resolves; the fallback only keeps the API non-optional.
    static let auraHome: URL = {
        var components = URLComponents()
        components.scheme = auraScheme
        components.host = "home"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    /// A scheme + host always resolves; the fallback only keeps the API non-optional.
    static let auraExtensions: URL = {
        var components = URLComponents()
        components.scheme = auraScheme
        components.host = "extensions"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    static func auraViewSource(of target: URL) -> URL {
        auraPageTool(host: "view-source", target: target)
    }

    static func auraReader(of target: URL) -> URL {
        auraPageTool(host: "reader", target: target)
    }

    /// Every reserved character in `target` is escaped, not just the ones a query
    /// technically has to escape: `URLComponents` leaves `+` alone when it builds a
    /// query item, and a `+` in a path is a space to whoever reads it back.
    private static func auraPageTool(host: String, target: URL) -> URL {
        var components = URLComponents()
        components.scheme = auraScheme
        components.host = host
        let escaped = target.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .auraUnreserved)
        components.percentEncodedQuery = "url=\(escaped ?? "")"
        // A scheme + host always resolves; the fallback only keeps the API non-optional.
        return components.url ?? auraHome
    }

    static func auraSettings(section: SettingsTab? = nil) -> URL {
        var components = URLComponents()
        components.scheme = auraScheme
        components.host = "settings"
        if let section { components.path = "/\(section.rawValue)" }
        // A scheme + host always resolves; the fallback only keeps the API non-optional.
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

private extension CharacterSet {
    /// RFC 3986's unreserved set. Everything else in a page tool's target is escaped.
    static let auraUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
