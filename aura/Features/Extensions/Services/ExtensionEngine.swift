import Foundation
@preconcurrency import WebKit

/// The 15.4+ half: owns the WKWebExtensionController shared by every
/// non-private page and the loaded contexts.
@available(macOS 15.4, *)
@MainActor
final class ExtensionEngine: NSObject {
    let controller = WKWebExtensionController(configuration: .default())
    private var contexts: [String: WKWebExtensionContext] = [:]

    override init() {
        super.init()
        controller.delegate = self
    }

    func context(for id: String) -> WKWebExtensionContext? {
        contexts[id]
    }

    func load(directory: URL, id: String) async throws -> WKWebExtension {
        if let existing = contexts[id] {
            return existing.webExtension
        }

        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: webExtension)
        // Stable identifier keeps chrome.storage data attached across launches.
        context.uniqueIdentifier = id

        // v1 trust model: installing an extension grants everything it asks for.
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
