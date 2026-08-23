import AppKit
import Foundation
@preconcurrency import WebKit

/// The AMO update path: what is newer, and replacing an installed add-on with it.
///
/// Split out of `ExtensionManager` for size only; everything here is that class.
extension ExtensionManager {
    /// The version AMO last reported for `id`, when it is newer than the installed one.
    /// Read from settings rather than memory so the offer survives a relaunch without
    /// another round trip to AMO.
    func availableUpdate(for id: String) -> String? {
        guard let latest = SettingsStore.shared.extensionAvailableUpdates[id],
              let entry = installedExtensions.first(where: { $0.id == id }),
              let current = entry.displayVersion,
              ExtensionVersion.isNewer(latest, than: current)
        else { return nil }
        return latest
    }

    /// Asks AMO what the newest version of every gecko-id'd extension is. Once a day
    /// on its own, immediately when the user presses the button in Settings. Nothing
    /// waits on it: the answer only decides whether a row grows an Update button.
    func checkForUpdates(force: Bool = false) {
        guard updateCheckTask == nil,
              ExtensionUpdates.isDue(lastCheck: SettingsStore.shared.extensionUpdateLastCheck, force: force)
        else { return }
        let installed = installedExtensions
        guard installed.contains(where: { $0.geckoID != nil }) else { return }

        updateCheckTask = Task { [weak self] in
            let found = await ExtensionUpdates.check(installed) { guid in
                try await FirefoxAddonStore.shared.addon(guid: guid)
            }
            guard !Task.isCancelled else { return }
            self?.adoptUpdateCheck(found)
        }
    }

    private func adoptUpdateCheck(_ found: [String: String]) {
        updateCheckTask = nil
        SettingsStore.shared.extensionUpdateLastCheck = Date()
        // Replaced wholesale: an id that no longer has an update must not keep an offer
        // from an earlier check, and neither must one that was removed.
        SettingsStore.shared.extensionAvailableUpdates = found
    }

    /// Re-downloads an add-on over its own directory.
    ///
    /// The folder id never changes, and it is what WebKit keys the extension's storage
    /// on (`uniqueIdentifier`), so an update keeps `browser.storage` and every setting
    /// the user made inside the extension. The shim patch is re-applied to the new
    /// files, and the load goes back through the consent gate: an update that asks for
    /// more than the user agreed to comes back through the sheet instead of loading.
    func updateExtension(_ id: String) async throws {
        guard !updatingIDs.contains(id),
              let entry = installedExtensions.first(where: { $0.id == id }),
              let geckoID = entry.geckoID
        else { return }
        updatingIDs.insert(id)
        defer { updatingIDs.remove(id) }

        let addon = try await FirefoxAddonStore.shared.addon(guid: geckoID)
        guard let downloadURL = addon.downloadURL else { throw FirefoxAddonStoreError.missingDownload }
        let archive = try await FirefoxAddonStore.shared.downloadXPI(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: archive) }

        let directory = entry.directoryURL
        let patchesShim = AuraWebBundle.isEnabled
        // Unpacking and copying an add-on is tens of megabytes of file work; the main
        // actor only comes back for the reload.
        let scanned = try await Task.detached(priority: .userInitiated) {
            try ExtensionManager.replaceContents(of: directory, withArchive: archive)
            return ExtensionManager.prepare(at: directory, patchesShim: patchesShim)
        }.value

        stopObservingErrors(of: id)
        if #available(macOS 15.4, *) {
            loadedEngine?.unload(id: id)
        }
        update(id: id) { item in
            item.displayName = scanned.displayName ?? item.displayName
            item.displayDescription = scanned.displayDescription
            item.displayVersion = scanned.displayVersion
            item.geckoID = scanned.geckoID ?? item.geckoID
            item.loadError = scanned.loadError
        }
        SettingsStore.shared.extensionAvailableUpdates[id] = nil

        guard let refreshed = installedExtensions.first(where: { $0.id == id }), refreshed.isEnabled else { return }
        loadIntoEngine(refreshed, source: Self.installSource(for: addon))
    }

    /// Unpacks `archive` over an installed extension's own folder.
    ///
    /// The old contents move aside first and are deleted only once the new ones are in
    /// place: a half-copied extension is one that no longer loads, and the failure to
    /// protect against is a download that unpacks badly, not one that never arrives.
    nonisolated static func replaceContents(of directory: URL, withArchive archive: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("aura-addon-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try XPIUnpacker.unpack(archive, to: staging)
        guard let root = XPIUnpacker.manifestRoot(in: staging) else {
            throw ExtensionInstallError.missingManifest
        }

        let backup = fileManager.temporaryDirectory
            .appendingPathComponent("aura-addon-previous-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: directory, to: backup)
        do {
            try fileManager.copyItem(at: root, to: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            try? fileManager.moveItem(at: backup, to: directory)
            throw error
        }
        try? fileManager.removeItem(at: backup)
    }
}
