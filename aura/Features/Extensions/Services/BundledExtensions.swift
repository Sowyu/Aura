import Foundation
import os

/// Add-ons that ship inside Aura rather than being fetched from a store.
///
/// Only uBlock Origin so far. It is unpacked into the profile on the first
/// launch that finds the marker missing, then treated exactly like a
/// hand-installed extension: the shim patch, the enable toggle and removal all
/// work the same way.
enum BundledExtensions {
    private static let markerKey = "extensions.bundled.ublock-origin"
    private static let folderName = "ublock-origin"
    private static let log = Logger(subsystem: "com.aurabrowser.app", category: "extensions")

    /// Unpacks anything bundled that this profile has not seen yet. The caller's
    /// directory scan picks the result up like any other folder, so it arrives
    /// installed and enabled.
    ///
    /// The marker is set once the extension is on disk, and it is what stops a
    /// user who removed uBlock Origin from finding it back tomorrow. A failed
    /// unpack leaves the marker alone: uBlock Origin is the only ad blocker Aura
    /// ships, so one bad first launch must not cost the profile its blocking
    /// forever.
    static func installIfNeeded(into extensionsDirectory: URL) {
        guard !UserDefaults.standard.bool(forKey: markerKey) else { return }
        guard let archive = uBlockArchiveURL else { return }

        do {
            // nil means the folder is already there, which counts as installed.
            let installed = try unpack(archive, named: folderName, into: extensionsDirectory)
            UserDefaults.standard.set(true, forKey: markerKey)
            log.info("installed bundled \(installed?.lastPathComponent ?? folderName, privacy: .public)")
        } catch {
            log.error("bundled install failed, retrying next launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Unpacks one archive into `extensionsDirectory` under a fixed folder name.
    /// Returns nil when that folder is already there, so this never overwrites a
    /// copy the user has been running.
    @discardableResult
    static func unpack(_ archive: URL, named folderName: String, into extensionsDirectory: URL) throws -> URL? {
        let destination = extensionsDirectory.appendingPathComponent(folderName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }

        // ponytail: ~15 MB unzipped on the main actor, once per profile. Move it
        // off if first launch ever starts feeling slow.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-bundled-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try XPIUnpacker.unpack(archive, to: staging)
            guard let root = XPIUnpacker.manifestRoot(in: staging) else { return nil }
            try FileManager.default.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// The archive Aura ships, for the install path and for the tests.
    static var uBlockArchiveURL: URL? {
        Bundle.main.url(forResource: folderName, withExtension: "xpi")
    }

    static var uBlockFolderName: String { folderName }
}
