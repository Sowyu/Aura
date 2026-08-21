import Foundation

/// How far an add-on can get under WebKit, decided from the permissions it declares
/// rather than from running it. The store shows this before anything is downloaded.
enum ExtensionCompatibility: Equatable {
    /// Nothing it asks for is missing.
    case supported
    /// Installs and mostly runs; the listed APIs are absent, so those features fail.
    case partial([String])
    /// The add-on's whole point depends on something WebKit has no equivalent of.
    case notSupported(String)

    var title: String {
        switch self {
        case .supported: return "Works on WebKit"
        case .partial: return "Partial"
        case .notSupported: return "Not supported"
        }
    }

    /// Tooltip text: which APIs are missing, or why the add-on can't work at all.
    var detail: String? {
        switch self {
        case .supported:
            return nil
        case let .partial(missing):
            return "WebKit has no: " + missing.joined(separator: ", ") + ". Everything else works."
        case let .notSupported(reason):
            return reason
        }
    }

    var allowsInstall: Bool {
        if case .notSupported = self { return false }
        return true
    }
}

extension ExtensionCompatibility {
    /// Permissions Firefox grants that WebKit has no implementation of. An extension
    /// asking for one installs, but its background script fails on first use.
    static let firefoxOnlyPermissions: Set<String> = [
        "webRequestBlocking", "proxy", "dns", "browserSettings", "contextualIdentities",
        "pkcs11", "captivePortal", "networkStatus", "geckoProfiler", "theme", "urlbar",
    ]

    /// Verdict for one AMO listing. Non-extension types are listed for completeness but
    /// never install: WebKit's extension support covers extensions only.
    static func evaluate(_ addon: FirefoxAddon) -> ExtensionCompatibility {
        switch addon.type {
        case .extension:
            return evaluate(permissions: addon.requestedPermissions)
        case .statictheme:
            return .notSupported("WebKit has no theme API, so a Firefox theme has nothing to apply itself to.")
        case .dictionary:
            return .notSupported("Spell-check dictionaries are a Firefox format; macOS supplies its own.")
        case .language:
            return .notSupported("Language packs translate Firefox's own interface, which Aura doesn't have.")
        }
    }

    /// The permission scan on its own, so an unpacked manifest can use the same rules.
    static func evaluate(permissions: [String]) -> ExtensionCompatibility {
        var seen: Set<String> = []
        let missing = permissions.filter { firefoxOnlyPermissions.contains($0) && seen.insert($0).inserted }
        guard !missing.isEmpty else { return .supported }

        // A theme permission with nothing else missing means theming is the whole add-on.
        if missing == ["theme"] {
            return .notSupported(
                "Theming the browser chrome is the point of this add-on, and WebKit has no API for it."
            )
        }
        let functional = missing

        if functional.contains("webRequestBlocking") {
            return .notSupported(
                "Blocking webRequest is how this add-on works, and WebKit only offers "
                    + "declarative content blocking."
            )
        }
        return .partial(functional)
    }
}
