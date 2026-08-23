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

    /// What blocking `webRequest` can and cannot do through Aura's injected bundle.
    ///
    /// The bundle hooks a request in the web process on its way out, which is what
    /// makes cancelling and redirecting exact. Two limits follow from where that hook
    /// sits, and they are stated here rather than left for a user to discover as an
    /// extension quietly misbehaving:
    ///
    /// - `onHeadersReceived` cannot change anything. The hook never sees a response,
    ///   and WebKit's injected-bundle API offers no response-header setter, so those
    ///   listeners run observe-only through WebKit's own `webRequest`. An extension
    ///   that injects a Content-Security-Policy from there (uBlock Origin's `csp=`
    ///   filters) has no effect in Aura.
    /// - `onBeforeSendHeaders` can add, change and drop headers, but only the ones the
    ///   request already carries at this point. Cookie and other headers the network
    ///   process adds afterwards are neither visible nor overridable, and a request
    ///   with a body that did not survive the bridge to `NSURLRequest` is left alone
    ///   rather than sent without it.
    static let requestHeaderCeiling =
        "Request headers can be changed; response headers (onHeadersReceived) cannot, "
            + "because the request is intercepted before any response exists."

    /// What an installed extension's row says about blocking `webRequest`, or nil when
    /// the extension never asked for it. Separate from the badge on purpose: blocking
    /// works, so the verdict stays "supported", and the ceiling belongs where the user
    /// is looking at one extension rather than on a store card.
    static func webRequestNote(permissions: [String]) -> String? {
        guard supportsBlockingWebRequest, permissions.contains("webRequestBlocking") else { return nil }
        return requestHeaderCeiling
    }

    /// Tooltip text: which APIs are missing, or why the add-on can't work at all.
    var detail: String? {
        switch self {
        case .supported:
            return nil
        case let .partial(missing):
            // Blocking webRequest is the one gap the user can close, so it gets its
            // own sentence instead of being listed as something WebKit lacks.
            if missing == ["webRequestBlocking"] {
                return "It blocks requests only with Settings > Privacy > Extension request blocking "
                    + "turned on, which is experimental. Everything else works."
            }
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
    ///
    /// `declarativeNetRequest` and `declarativeNetRequestWithHostAccess` are missing
    /// from this list on purpose: WebKit compiles and enforces DNR rule sets itself,
    /// so an MV3 blocker like uBlock Origin Lite is fully supported and blocks for
    /// real with nothing switched on.
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

    /// Whether Aura answers blocking `webRequest` itself. The injected bundle
    /// stops the request inside the web process and `WebRequestBroker` asks the
    /// extension, so the answer is simply whether that bundle is loaded.
    static var supportsBlockingWebRequest: Bool {
        guard #available(macOS 15.4, *) else { return false }
        // A failed health probe outranks both: the bundle is not answering on this
        // OS build, so promising an extension its blocking listener works would be
        // a lie for the rest of the session.
        if SettingsStore.shared.requestBlockingUnavailable { return false }
        // The live setting, not the process-wide constant: the store badge should
        // flip as soon as the user turns request blocking on, even before relaunch.
        if let override = ProcessInfo.processInfo.environment["AURA_WEB_BUNDLE"] { return override != "0" }
        return SettingsStore.shared.extensionRequestBlocking
    }

    /// The permission scan on its own, so an unpacked manifest can use the same rules.
    static func evaluate(permissions: [String]) -> ExtensionCompatibility {
        var unsupported = firefoxOnlyPermissions
        if supportsBlockingWebRequest { unsupported.remove("webRequestBlocking") }

        var seen: Set<String> = []
        let missing = permissions.filter { unsupported.contains($0) && seen.insert($0).inserted }
        guard !missing.isEmpty else { return .supported }

        // A theme permission with nothing else missing means theming is the whole add-on.
        if missing == ["theme"] {
            return .notSupported(
                "Theming the browser chrome is the point of this add-on, and WebKit has no API for it."
            )
        }
        let functional = missing

        // Blocking webRequest is available behind Settings > Privacy > Extension request
        // blocking. Until that is on, the add-on installs and runs everything else.
        return .partial(functional)
    }
}

extension ExtensionCompatibility {
    /// What each manifest permission lets an extension do, in words a user can weigh
    /// before agreeing. Only the ones extensions actually ask for; anything else falls
    /// through to its manifest key.
    private static let permissionWording: [String: String] = [
        "<all_urls>": "Read and change data on every site you visit",
        "activeTab": "Read and change data on the tab you are using",
        "tabs": "Read the tabs you have open",
        "storage": "Store data on this Mac",
        "unlimitedStorage": "Store data on this Mac without a size limit",
        "cookies": "Read and change cookies",
        "webRequest": "Watch every request pages make",
        "webRequestBlocking": "Stop requests before they leave your Mac",
        "declarativeNetRequest": "Block requests from its own rule list",
        "declarativeNetRequestWithHostAccess": "Block requests from its own rule list",
        "history": "Read and change your browsing history",
        "bookmarks": "Read and change your bookmarks",
        "downloads": "Start and manage downloads",
        "clipboardRead": "Read your clipboard",
        "clipboardWrite": "Write to your clipboard",
        "notifications": "Show notifications",
        "scripting": "Run its own code on pages",
        "nativeMessaging": "Talk to programs outside Aura",
        "management": "See and change your other extensions",
        "proxy": "Change how Aura connects to the internet",
        "privacy": "Change your privacy settings",
        "contextMenus": "Add items to the right-click menu",
        "menus": "Add items to the right-click menu",
        "alarms": "Run work on a schedule in the background",
        "webNavigation": "See every page you navigate to",
    ]

    /// One permission in human form. Host access arrives as a URL match pattern rather
    /// than a name, so the host comes out of the pattern; a pattern matching everything
    /// says so. Anything with no wording is shown raw, because hiding a permission from
    /// the sheet is worse than showing a manifest key.
    static func humanPermission(_ raw: String) -> String {
        if let wording = permissionWording[raw] { return wording }
        guard raw.contains("://") || raw.hasPrefix("*.") else { return raw }

        let afterScheme = raw.components(separatedBy: "://").last ?? raw
        let host = afterScheme.components(separatedBy: "/").first ?? afterScheme
        let bare = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        guard !bare.isEmpty, bare != "*" else {
            return "Read and change data on every site you visit"
        }
        return "Read and change data on \(bare)"
    }
}
