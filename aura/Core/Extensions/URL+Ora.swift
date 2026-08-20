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

    /// The settings section a `aura://settings/<section>` URL points at, if it names a known one.
    var oraSettingsSection: SettingsTab? {
        guard isOraSettings else { return nil }
        guard let raw = pathComponents.first(where: { $0 != "/" }) else { return nil }
        return SettingsTab(rawValue: raw)
    }

    /// `ora://x` rewritten to `aura://x`. Any other URL comes back untouched.
    var canonicalOraInternal: URL {
        guard scheme?.lowercased() == Self.legacyOraScheme,
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        else { return self }
        components.scheme = Self.oraScheme
        return components.url ?? self
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
