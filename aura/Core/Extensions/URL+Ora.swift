import Foundation

/// Internal pages use the `aura://` scheme (for example `aura://settings/spaces`).
/// They render as native SwiftUI inside a tab and are never handed to WebKit.
extension URL {
    static let oraScheme = "aura"

    /// Pre-rename scheme. Saved tabs and typed addresses still use it, so it stays
    /// readable forever; anything opened through `oraInternalURL(from:)` comes back
    /// rewritten to `auraScheme`.
    static let legacyOraScheme = "ora"

    var isOraInternal: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == Self.oraScheme || scheme == Self.legacyOraScheme
    }

    var isOraSettings: Bool {
        isOraInternal && host?.lowercased() == "settings"
    }

    /// `aura://home`: the new-tab page, rendered natively like settings.
    var isOraHome: Bool {
        isOraInternal && host?.lowercased() == "home"
    }

    /// `aura://extensions`: the add-on store, rendered natively like settings.
    var isOraExtensions: Bool {
        isOraInternal && host?.lowercased() == "extensions"
    }

    /// `aura://view-source?url=…`: the page's HTML, rendered natively with line numbers.
    var isOraViewSource: Bool {
        isOraInternal && host?.lowercased() == "view-source"
    }

    /// `aura://reader?url=…`: the article text of a page, rendered natively.
    var isOraReader: Bool {
        isOraInternal && host?.lowercased() == "reader"
    }

    /// The page a view-source or reader address describes. Reading goes through
    /// `queryItems`, which undoes the escaping `oraPageTool` applied.
    var oraPageToolTarget: URL? {
        guard isOraViewSource || isOraReader,
              let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value
        else { return nil }
        return URL(string: raw)
    }

    /// The settings section a `aura://settings/<section>` URL points at, if it names a known one.
    var oraSettingsSection: SettingsTab? {
        guard isOraSettings else { return nil }
        guard let raw = pathComponents.first(where: { $0 != "/" }) else { return nil }
        return SettingsTab.resolve(rawValue: raw)
    }

    /// `ora://x` rewritten to `aura://x`. Any other URL comes back untouched.
    var canonicalOraInternal: URL {
        guard scheme?.lowercased() == Self.legacyOraScheme,
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        else { return self }
        components.scheme = Self.oraScheme
        return components.url ?? self
    }

    /// A scheme + host always resolves; the fallback only keeps the API non-optional.
    static let oraHome: URL = {
        var components = URLComponents()
        components.scheme = oraScheme
        components.host = "home"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    /// A scheme + host always resolves; the fallback only keeps the API non-optional.
    static let oraExtensions: URL = {
        var components = URLComponents()
        components.scheme = oraScheme
        components.host = "extensions"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    static func oraViewSource(of target: URL) -> URL {
        oraPageTool(host: "view-source", target: target)
    }

    static func oraReader(of target: URL) -> URL {
        oraPageTool(host: "reader", target: target)
    }

    /// Every reserved character in `target` is escaped, not just the ones a query
    /// technically has to escape: `URLComponents` leaves `+` alone when it builds a
    /// query item, and a `+` in a path is a space to whoever reads it back.
    private static func oraPageTool(host: String, target: URL) -> URL {
        var components = URLComponents()
        components.scheme = oraScheme
        components.host = host
        let escaped = target.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .oraUnreserved)
        components.percentEncodedQuery = "url=\(escaped ?? "")"
        // A scheme + host always resolves; the fallback only keeps the API non-optional.
        return components.url ?? oraHome
    }

    static func oraSettings(section: SettingsTab? = nil) -> URL {
        var components = URLComponents()
        components.scheme = oraScheme
        components.host = "settings"
        if let section { components.path = "/\(section.rawValue)" }
        // A scheme + host always resolves; the fallback only keeps the API non-optional.
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

private extension CharacterSet {
    /// RFC 3986's unreserved set. Everything else in a page tool's target is escaped.
    static let oraUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
