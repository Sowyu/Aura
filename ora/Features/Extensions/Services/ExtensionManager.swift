import AppKit
import Foundation
@preconcurrency import WebKit

/// One installed extension as shown in Settings. Mirrored from disk so the
/// list renders even before WebKit finishes loading the extension (or on
/// systems where WKWebExtension is unavailable).
struct InstalledExtension: Identifiable, Equatable {
    let id: String
    let directoryURL: URL
    var displayName: String
    var displayVersion: String?
    var isEnabled: Bool
    var icon: NSImage?
    var loadError: String?
}

enum ExtensionInstallError: LocalizedError {
    case missingManifest
    case alreadyInstalled(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "The selected folder doesn't contain a manifest.json file."
        case let .alreadyInstalled(name):
            return "\"\(name)\" is already installed."
        }
    }
}

/// Loads unpacked web extensions (a folder containing manifest.json) through
/// WebKit's native web-extension support and exposes them to Settings.
///
/// v1 scope: extensions run in normal windows only (never private), and every
/// permission an extension requests is granted at install time. Toolbar
/// actions, popups, and the tabs API bridge are follow-up work.
@MainActor
final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()

    @Published private(set) var installedExtensions: [InstalledExtension] = []

    static var isSupported: Bool {
        guard #available(macOS 15.4, *) else { return false }
        return true
    }

    private static let disabledIDsKey = "extensions.disabledIDs"

    private var hasStarted = false
    /// AnyObject storage because WKWebExtensionController's type is 15.4+;
    /// typed access goes through the `engine` accessor below.
    private var engineStorage: AnyObject?

    @available(macOS 15.4, *)
    private var engine: ExtensionEngine {
        if let engine = engineStorage as? ExtensionEngine {
            return engine
        }
        let engine = ExtensionEngine()
        engineStorage = engine
        return engine
    }

    var extensionsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Ora/Extensions", isDirectory: true)
    }

    private var disabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.disabledIDsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.disabledIDsKey) }
    }

    // MARK: - Wiring

    /// Called from BrowserPage while building its WKWebViewConfiguration.
    func attach(to configuration: WKWebViewConfiguration, isPrivate: Bool) {
        guard #available(macOS 15.4, *), !isPrivate else { return }
        configuration.webExtensionController = engine.controller
        start()
    }

    /// Scans the extensions directory and loads every enabled extension.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        let directories = (try? fileManager.contentsOfDirectory(
            at: extensionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for directory in directories where (try? directory.resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory) == true {
            registerExtension(at: directory)
        }
    }

    // MARK: - Install / remove / toggle

    /// Copies an unpacked extension folder into the extensions directory and loads it.
    func installExtension(from sourceURL: URL) throws {
        let manifestURL = sourceURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExtensionInstallError.missingManifest
        }

        let manifest = Self.parseManifest(at: manifestURL)
        let name = manifest.name ?? sourceURL.lastPathComponent
        if installedExtensions.contains(where: { $0.displayName == name }) {
            throw ExtensionInstallError.alreadyInstalled(name)
        }

        start()
        let id = Self.sanitizedID(from: name)
        let destination = extensionsDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        registerExtension(at: destination)
    }

    /// Downloads a Firefox add-on's .xpi from addons.mozilla.org, unpacks it,
    /// and installs it like any other unpacked extension.
    func installFirefoxAddon(_ addon: FirefoxAddon) async throws {
        guard let downloadURL = addon.downloadURL else {
            throw FirefoxAddonStoreError.missingDownload
        }
        start()

        let archive = try await FirefoxAddonStore.shared.downloadXPI(from: downloadURL)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-addon-unpack-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: staging)
        }

        try XPIUnpacker.unpack(archive, to: staging)
        guard let root = XPIUnpacker.manifestRoot(in: staging) else {
            throw ExtensionInstallError.missingManifest
        }
        try installExtension(from: root)
    }

    func removeExtension(_ id: String) {
        if #available(macOS 15.4, *) {
            engine.unload(id: id)
        }
        if let index = installedExtensions.firstIndex(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: installedExtensions[index].directoryURL)
            installedExtensions.remove(at: index)
        }
        disabledIDs.remove(id)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = installedExtensions.firstIndex(where: { $0.id == id }) else { return }
        installedExtensions[index].isEnabled = enabled
        installedExtensions[index].loadError = nil
        if enabled {
            disabledIDs.remove(id)
            loadIntoEngine(installedExtensions[index])
        } else {
            disabledIDs.insert(id)
            if #available(macOS 15.4, *) {
                engine.unload(id: id)
            }
        }
    }

    // MARK: - Loading

    private func registerExtension(at directory: URL) {
        let id = directory.lastPathComponent
        guard !installedExtensions.contains(where: { $0.id == id }) else { return }

        let manifest = Self.parseManifest(at: directory.appendingPathComponent("manifest.json"))
        let entry = InstalledExtension(
            id: id,
            directoryURL: directory,
            displayName: manifest.name ?? id,
            displayVersion: manifest.version,
            isEnabled: !disabledIDs.contains(id),
            icon: nil,
            loadError: nil
        )
        installedExtensions.append(entry)

        if entry.isEnabled {
            loadIntoEngine(entry)
        }
    }

    private func loadIntoEngine(_ entry: InstalledExtension) {
        guard #available(macOS 15.4, *) else { return }
        Task { @MainActor in
            do {
                let loaded = try await engine.load(directory: entry.directoryURL, id: entry.id)
                update(id: entry.id) { item in
                    item.displayName = loaded.displayName ?? item.displayName
                    item.displayVersion = loaded.displayVersion ?? item.displayVersion
                    item.icon = loaded.icon(for: CGSize(width: 32, height: 32))
                    item.loadError = nil
                }
            } catch {
                update(id: entry.id) { item in
                    item.loadError = error.localizedDescription
                }
            }
        }
    }

    private func update(id: String, _ mutate: (inout InstalledExtension) -> Void) {
        guard let index = installedExtensions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&installedExtensions[index])
    }

    // MARK: - Manifest helpers

    private static func parseManifest(at url: URL) -> (name: String?, version: String?) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, nil)
        }
        // "__MSG_*__" names live in locale files; fall back to the folder name.
        let rawName = json["name"] as? String
        let name = rawName?.hasPrefix("__MSG_") == true ? nil : rawName
        return (name, json["version"] as? String)
    }

    private static func sanitizedID(from name: String) -> String {
        let allowed = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            + "-" + UUID().uuidString.prefix(8).lowercased()
    }
}

/// The 15.4+ half: owns the WKWebExtensionController shared by every
/// non-private page and the loaded contexts.
@available(macOS 15.4, *)
@MainActor
final class ExtensionEngine {
    let controller = WKWebExtensionController(configuration: .default())
    private var contexts: [String: WKWebExtensionContext] = [:]

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
    }
}
