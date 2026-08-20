import Foundation

/// Internal pages use the `ora://` scheme (for example `ora://settings/spaces`).
/// They render as native SwiftUI inside a tab and are never handed to WebKit.
extension URL {
    static let oraScheme = "ora"

    var isOraInternal: Bool {
        scheme?.lowercased() == Self.oraScheme
    }

    var isOraSettings: Bool {
        isOraInternal && host?.lowercased() == "settings"
    }

    /// The settings section a `ora://settings/<section>` URL points at, if it names a known one.
    var oraSettingsSection: SettingsTab? {
        guard isOraSettings else { return nil }
        guard let raw = pathComponents.first(where: { $0 != "/" }) else { return nil }
        return SettingsTab(rawValue: raw)
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
