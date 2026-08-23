import CryptoKit
import Foundation
@preconcurrency import WebKit

/// What the user agreed to for one extension, kept in `SettingsStore.extensionConsent`.
/// The permission set is stored as a hash rather than a list: the live manifest is what
/// the sheet reads anyway, and this only has to answer "same as what was shown".
struct ExtensionConsentRecord: Codable, Equatable {
    var version: String
    var permissionsHash: String
}

/// Where an install came from. On the sheet this is the difference between "I clicked
/// install on addons.mozilla.org" and "something put a folder in my profile".
enum ExtensionInstallSource: Equatable {
    case folder(String)
    case archive(String)
    case addonStore(String)
    case bundled

    var label: String {
        switch self {
        case let .folder(name): return "Folder \(name)"
        case let .archive(name): return "File \(name)"
        case let .addonStore(guid): return "addons.mozilla.org (\(guid))"
        case .bundled: return "Bundled with Aura"
        }
    }
}

/// One install waiting on the user. Everything the sheet shows is read off the manifest
/// once, here, so the view never touches disk.
struct ExtensionConsentRequest: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// What the add-on says it does, in the user's language. Nil when the manifest
    /// carries no description, which plenty of unpacked folders do not.
    var displayDescription: String?
    let version: String?
    let source: ExtensionInstallSource
    let permissions: [String]

    var permissionsHash: String {
        ExtensionConsent.permissionsHash(permissions)
    }

    var compatibility: ExtensionCompatibility {
        ExtensionCompatibility.evaluate(permissions: permissions)
    }

    /// The permissions in the words the sheet shows. Two manifest keys can map to one
    /// sentence (`<all_urls>` and `*://*/*`), so the duplicates go.
    var permissionLines: [String] {
        var seen: Set<String> = []
        return permissions
            .map(ExtensionCompatibility.humanPermission)
            .filter { seen.insert($0).inserted }
    }
}

/// Whether an extension may load without asking. Kept separate from the manager so the
/// rule is a pure function of what is installed and what was agreed to.
enum ExtensionConsent {
    enum Decision: Equatable {
        case load
        case prompt
    }

    /// Order-independent fingerprint of everything an extension asked for. Manifests
    /// list permissions in whatever order they please, and a reorder is not a change.
    static func permissionsHash(_ permissions: [String]) -> String {
        let normalized = Set(permissions).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Any change to the permission set asks again, not only growth: a stored hash
    /// cannot tell "added tabs" from "dropped tabs, added <all_urls>", and asking once
    /// too often is the cheap mistake. A version bump on its own is an update, so it
    /// loads headless.
    static func decision(for request: ExtensionConsentRequest, stored: ExtensionConsentRecord?) -> Decision {
        // uBlock Origin Lite ships inside the app bundle. Installing Aura is the consent,
        // and prompting on first launch for something the user never chose is noise.
        if case .bundled = request.source { return .load }
        guard let stored else { return .prompt }
        return stored.permissionsHash == request.permissionsHash ? .load : .prompt
    }

    /// What to persist once the user says yes: exactly the version and the permission
    /// set that were on screen.
    static func record(for request: ExtensionConsentRequest) -> ExtensionConsentRecord {
        ExtensionConsentRecord(version: request.version ?? "", permissionsHash: request.permissionsHash)
    }
}

/// The 15.4+ half: owns the WKWebExtensionController shared by every
/// non-private page and the loaded contexts.
@available(macOS 15.4, *)
@MainActor
final class ExtensionEngine: NSObject {
    /// `.default()` is the persistent configuration, and it has to stay that way:
    /// WebKit caches the compiled declarativeNetRequest rules against it, so uBO
    /// Lite's ~100k rules cost about 30 s on first launch and seconds after. A
    /// non-persistent configuration would recompile them every launch.
    let controller = WKWebExtensionController(configuration: .default())
    private var contexts: [String: WKWebExtensionContext] = [:]

    override init() {
        super.init()
        controller.delegate = self
    }

    func context(for id: String) -> WKWebExtensionContext? {
        contexts[id]
    }

    /// Every loaded context, for the callers that work across all of them (keyboard
    /// commands, and the data purge an uninstall runs).
    var loadedContexts: [String: WKWebExtensionContext] {
        contexts
    }

    func load(directory: URL, id: String, privateAccess: Bool = false) async throws -> WKWebExtension {
        if let existing = contexts[id] {
            existing.hasAccessToPrivateData = privateAccess
            return existing.webExtension
        }

        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: webExtension)
        // Stable identifier keeps chrome.storage data attached across launches.
        context.uniqueIdentifier = id
        // Firefox's model: the extension runs everywhere, but private windows, tabs and
        // cookies stay invisible to it until the user says otherwise. WebKit does the
        // filtering itself once this is set, so nothing downstream has to remember which
        // extension was allowed in.
        context.hasAccessToPrivateData = privateAccess

        // Everything the manifest asks for is granted here, which is only safe because
        // nothing reaches this call until `ExtensionConsent` says the user saw the same
        // list and agreed to it.
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }

        try controller.load(context)
        contexts[id] = context
        return webExtension
    }

    /// Flips one loaded extension's private-browsing access. Takes effect on the next
    /// page load in a private window; WebKit does not retro-fit already-open ones.
    func setPrivateAccess(_ allowed: Bool, for id: String) {
        contexts[id]?.hasAccessToPrivateData = allowed
    }

    func unload(id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        // The native ports the extension's shim opened outlive the context.
        // A blocking listener left registered against a port nobody answers on
        // keeps the injected bundle asking, and every ask then costs the broker
        // its full timeout, so a disabled extension would slow every page down.
        WebRequestBroker.shared.detach(extensionID: id)
        ExtensionMessageRelay.shared.detach(extensionID: id)
    }
}
