import AppKit
import Foundation
@preconcurrency import WebKit

/// Loading half of `ExtensionManager`: the consent gate an extension passes before
/// WebKit ever sees it, and the errors its own code reports afterwards.
///
/// Split out of the class for size only; everything here is that class.
extension ExtensionManager {
    // MARK: - Loading

    func registerExtension(at directory: URL, source: ExtensionInstallSource) {
        register(Self.prepare(at: directory, patchesShim: AuraWebBundle.isEnabled), source: source)
    }

    func register(_ scanned: ScannedExtension, source: ExtensionInstallSource? = nil) {
        guard !installedExtensions.contains(where: { $0.id == scanned.id }) else { return }

        let entry = InstalledExtension(
            id: scanned.id,
            directoryURL: scanned.directoryURL,
            displayName: scanned.displayName ?? scanned.id,
            displayDescription: scanned.displayDescription,
            displayVersion: scanned.displayVersion,
            geckoID: scanned.geckoID,
            isEnabled: !disabledIDs.contains(scanned.id),
            icon: nil,
            loadError: scanned.loadError
        )
        installedExtensions.append(entry)

        if entry.isEnabled {
            loadIntoEngine(entry, source: source)
        }
    }

    /// The consent gate. Nothing reaches `engine.load` until the permissions in this
    /// extension's manifest are ones the user has agreed to for this id.
    func loadIntoEngine(_ entry: InstalledExtension, source: ExtensionInstallSource? = nil) {
        guard #available(macOS 15.4, *) else { return }

        let request = Self.consentRequest(for: entry, source: source ?? Self.installSource(for: entry))
        switch ExtensionConsent.decision(for: request, stored: SettingsStore.shared.extensionConsent[entry.id]) {
        case .load:
            performLoad(entry)
        case .prompt:
            if !pendingConsent.contains(where: { $0.id == request.id }) {
                pendingConsent.append(request)
            }
            update(id: entry.id) { $0.loadError = Self.awaitingConsentNote }
        }
    }

    /// Everything the sheet shows for one installed extension, read off its manifest.
    static func consentRequest(
        for entry: InstalledExtension,
        source: ExtensionInstallSource
    ) -> ExtensionConsentRequest {
        ExtensionConsentRequest(
            id: entry.id,
            displayName: entry.displayName,
            displayDescription: entry.displayDescription,
            version: entry.displayVersion,
            source: source,
            permissions: requestedPermissions(at: entry.directoryURL)
        )
    }

    /// Where an already-installed extension came from, as far as anything still knows.
    /// Only the bundled one is certain, and that is the one the answer matters for.
    static func installSource(for entry: InstalledExtension) -> ExtensionInstallSource {
        BundledExtensions.isBundled(id: entry.id, geckoID: entry.geckoID)
            ? .bundled
            : .folder(entry.directoryURL.lastPathComponent)
    }

    func claimConsentPresentation(_ id: String) -> Bool {
        presentingConsent.insert(id).inserted
    }

    func releaseConsentPresentation(_ id: String) {
        presentingConsent.remove(id)
    }

    /// The user said yes. The exact version and permission set that were on screen are
    /// what gets recorded, so an update asking for more comes back through the sheet.
    /// The private-window answer is recorded first: the load below reads it.
    func approveConsent(_ request: ExtensionConsentRequest, allowsPrivateWindows: Bool = false) {
        setRunsInPrivateWindows(allowsPrivateWindows, for: request.id)
        SettingsStore.shared.extensionConsent[request.id] = ExtensionConsent.record(for: request)
        pendingConsent.removeAll { $0.id == request.id }
        guard let entry = installedExtensions.first(where: { $0.id == request.id }) else { return }
        update(id: request.id) { $0.loadError = nil }
        performLoad(entry)
    }

    /// The user said no, or dismissed the sheet without answering. The files are already
    /// in the profile by then, but deleting them on what may have been a stray click is
    /// worse than leaving an extension switched off: the store row's toggle asks again.
    func declineConsent(_ request: ExtensionConsentRequest) {
        pendingConsent.removeAll { $0.id == request.id }
        setEnabled(false, for: request.id)
    }

    func performLoad(_ entry: InstalledExtension) {
        guard #available(macOS 15.4, *) else { return }
        Task { @MainActor in
            do {
                let loaded = try await engine.load(
                    directory: entry.directoryURL,
                    id: entry.id,
                    privateAccess: runsInPrivateWindows(entry.id)
                )
                update(id: entry.id) { item in
                    item.displayName = loaded.displayName ?? item.displayName
                    item.displayVersion = loaded.displayVersion ?? item.displayVersion
                    item.icon = loaded.icon(for: CGSize(width: 32, height: 32))
                    item.loadError = Self.compatibilityNote(at: entry.directoryURL)
                }
                observeErrors(of: entry.id)
                applyCommandShortcuts()
                // A background script fails asynchronously, and used to be given a flat
                // three seconds to do it in before its errors were read once and never
                // again. The observer above is what reports them now, whenever they
                // happen; this is only the state at load time.
                //
                // Deliberately not `loadBackgroundContent()`: forcing the background up
                // would report errors sooner and cost every launch the start-up of every
                // MV3 worker WebKit was keeping lazy, uBlock Origin Lite's rule compile
                // included.
                refreshErrors(for: entry.id)
            } catch {
                update(id: entry.id) { item in
                    item.loadError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Runtime errors

    /// Watches a loaded extension's error list. WebKit posts on every change, so a
    /// background script that throws ten minutes in shows up in the row then, rather
    /// than being missed by a snapshot taken at load time.
    @available(macOS 15.4, *)
    func observeErrors(of id: String) {
        guard errorObservers[id] == nil, let context = engine.context(for: id) else { return }
        errorObservers[id] = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification,
            object: context,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshErrors(for: id) }
        }
    }

    /// Internal rather than private: an update unloads the context from a sibling file.
    func stopObservingErrors(of id: String) {
        guard let observer = errorObservers.removeValue(forKey: id) else { return }
        NotificationCenter.default.removeObserver(observer)
    }

    /// Rewrites one row's note from what the context currently reports.
    func refreshErrors(for id: String) {
        guard #available(macOS 15.4, *),
              let entry = installedExtensions.first(where: { $0.id == id }),
              let context = loadedEngine?.context(for: id)
        else { return }
        let note = Self.rowNote(
            compatibility: Self.compatibilityNote(at: entry.directoryURL),
            errors: context.errors.map(\.localizedDescription)
        )
        update(id: id) { $0.loadError = note }
    }

    /// What the row says under an extension's name: what WebKit cannot do for it, then
    /// what its own code has thrown. Only the first error, because the row is two lines
    /// and a wedged extension reports the same failure a hundred times.
    static func rowNote(compatibility: String?, errors: [String]) -> String? {
        let runtime = errors.first.map { "Runtime: " + $0 }
        let parts = [compatibility, runtime].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Internal rather than private: the extensions in the sibling files write rows
    /// through it.
    func update(id: String, _ mutate: (inout InstalledExtension) -> Void) {
        guard let index = installedExtensions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&installedExtensions[index])
    }
}
