import Foundation
import os
@preconcurrency import WebKit

/// Carries `runtime.connect` and `runtime.sendMessage` between an extension's
/// own pages and its background page.
///
/// WKWebExtension drops both. A popup that calls `runtime.connect` gets a port
/// object back, posts to it, and nothing ever reaches `runtime.onConnect` on the
/// background side, which is why uBlock Origin's popup and dashboard came up
/// empty. Content scripts are unaffected and keep WebKit's own path.
///
/// The two ends open native message ports with different application
/// identifiers, so this class knows which side a port belongs to the moment it
/// arrives and needs no handshake. It reads nothing out of a frame except
/// `portId`, which the page mints; everything else is passed through untouched.
@available(macOS 15.4, *)
@MainActor
final class ExtensionMessageRelay {
    static let shared = ExtensionMessageRelay()

    nonisolated static let backgroundIdentifier = "app.aurabrowser.relay.background"
    nonisolated static let pageIdentifier = "app.aurabrowser.relay.page"

    private static let log = Logger(subsystem: "com.aurabrowser.app", category: "extensions")

    /// One per extension. WebKit keeps a background page alive for as long as
    /// the extension is loaded, so this is stable.
    private var backgroundPorts: [String: WKWebExtension.MessagePort] = [:]
    /// Which page opened each tunnelled port, so the background's replies know
    /// where to go. Keyed by extension, then by the page-minted port id.
    private var owners: [String: [String: WKWebExtension.MessagePort]] = [:]
    /// Frames from a page that arrived before the background page connected.
    /// Capped: a background page that never connects must not grow this forever.
    private var queued: [String: [[String: Any]]] = [:]

    private static let queueLimit = 128

    private init() {}

    // MARK: - Ports

    func attachBackground(port: WKWebExtension.MessagePort, extensionID: String) {
        backgroundPorts[extensionID]?.disconnect()
        backgroundPorts[extensionID] = port

        port.messageHandler = { [weak self] message, _ in
            MainActor.assumeIsolated { self?.fromBackground(message, extensionID: extensionID) }
        }
        port.disconnectHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.backgroundDidDisconnect(extensionID: extensionID) }
        }

        let waiting = queued.removeValue(forKey: extensionID) ?? []
        for frame in waiting { port.sendMessage(frame, completionHandler: nil) }
        Self.log.info("relay: background attached for \(extensionID, privacy: .public)")
    }

    func attachPage(port: WKWebExtension.MessagePort, extensionID: String) {
        // A popup WebKit tore down without calling its disconnect handler would
        // otherwise leave its tunnelled ports in `owners` for good, and every
        // reopen would add more. Fifty popup opens, fifty leaked entries.
        pruneDeadOwners(for: extensionID)
        port.messageHandler = { [weak self] message, _ in
            MainActor.assumeIsolated { self?.fromPage(message, port: port, extensionID: extensionID) }
        }
        port.disconnectHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.pageDidDisconnect(port, extensionID: extensionID) }
        }
    }

    // MARK: - Routing

    private func fromPage(_ message: Any?, port: WKWebExtension.MessagePort, extensionID: String) {
        guard let frame = message as? [String: Any],
              let portID = frame["portId"] as? String,
              let operation = frame["op"] as? String
        else { return }

        switch operation {
        case "connect", "message":
            owners[extensionID, default: [:]][portID] = port
        case "disconnect":
            owners[extensionID]?.removeValue(forKey: portID)
        default:
            break
        }
        sendToBackground(frame, extensionID: extensionID)
    }

    private func fromBackground(_ message: Any?, extensionID: String) {
        guard let frame = message as? [String: Any],
              let portID = frame["portId"] as? String,
              let operation = frame["op"] as? String,
              let page = owners[extensionID]?[portID]
        else { return }

        // Both close the tunnelled port: a one-shot reply has no second message.
        if operation == "disconnect" || operation == "response" {
            owners[extensionID]?.removeValue(forKey: portID)
        }
        guard !page.isDisconnected else { return }
        page.sendMessage(frame, completionHandler: nil)
    }

    private func sendToBackground(_ frame: [String: Any], extensionID: String) {
        guard let background = backgroundPorts[extensionID], !background.isDisconnected else {
            var waiting = queued[extensionID] ?? []
            if waiting.count < Self.queueLimit { waiting.append(frame) }
            queued[extensionID] = waiting
            return
        }
        background.sendMessage(frame, completionHandler: nil)
    }

    // MARK: - Teardown

    /// A popup dismissed or a dashboard tab closed. The background page is still
    /// holding the port it was handed, so it has to be told.
    private func pageDidDisconnect(_ port: WKWebExtension.MessagePort, extensionID: String) {
        guard var owned = owners[extensionID] else { return }
        let orphaned = owned.filter { $0.value === port }.map(\.key)
        for portID in orphaned {
            owned.removeValue(forKey: portID)
            sendToBackground(["op": "disconnect", "portId": portID], extensionID: extensionID)
        }
        owners[extensionID] = owned.isEmpty ? nil : owned
    }

    /// The extension went away (disabled, removed, or reloaded). WebKit does not
    /// reliably disconnect the native ports it opened, so unloading says so here
    /// rather than waiting for a disconnect handler that may never fire.
    func detach(extensionID: String) {
        backgroundPorts.removeValue(forKey: extensionID)?.disconnect()
        queued.removeValue(forKey: extensionID)
        for page in (owners.removeValue(forKey: extensionID) ?? [:]).values where !page.isDisconnected {
            page.disconnect()
        }
    }

    private func pruneDeadOwners(for extensionID: String) {
        guard var owned = owners[extensionID] else { return }
        let dead = owned.filter { $0.value.isDisconnected }.map(\.key)
        guard !dead.isEmpty else { return }
        for portID in dead {
            owned.removeValue(forKey: portID)
            sendToBackground(["op": "disconnect", "portId": portID], extensionID: extensionID)
        }
        owners[extensionID] = owned.isEmpty ? nil : owned
    }

    private func backgroundDidDisconnect(extensionID: String) {
        backgroundPorts.removeValue(forKey: extensionID)
        queued.removeValue(forKey: extensionID)
        for (portID, page) in owners.removeValue(forKey: extensionID) ?? [:] where !page.isDisconnected {
            page.sendMessage(["op": "disconnect", "portId": portID], completionHandler: nil)
        }
    }

    // MARK: - Diagnostics

    /// Open tunnelled ports for an extension. The tests read this to prove a
    /// connect reached the host rather than dying in the page.
    func openPortCount(for extensionID: String) -> Int {
        owners[extensionID]?.count ?? 0
    }

    func hasBackground(for extensionID: String) -> Bool {
        guard let port = backgroundPorts[extensionID] else { return false }
        return !port.isDisconnected
    }
}
