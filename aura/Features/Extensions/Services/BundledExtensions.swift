import CryptoKit
import Foundation
import os

/// Add-ons that ship inside Aura rather than being fetched from a store.
///
/// Two archives, one blocker at a time. uBlock Origin Lite is unpacked into the
/// profile on the first launch that finds the marker missing, then treated
/// exactly like a hand-installed extension: the shim patch, the enable toggle
/// and removal all work the same way.
///
/// uBO Lite blocks through `declarativeNetRequest`, which WebKit compiles and
/// enforces itself. Full uBlock Origin blocks through `webRequest`, which only
/// answers with Aura's injected bundle loaded, and that bundle has been known to
/// stop pages painting on this macOS. So Lite is the default and full uBO is
/// opt-in, behind the switch in Settings > Privacy and behind the health probe
/// that takes it away again if pages stop painting. `plan(for:)` is the rule
/// that decides which of the two a given launch runs.
enum BundledExtensions {
    private static let markerKey = "extensions.bundled.ublock-origin-lite"
    private static let folderName = "ublock-origin-lite"
    /// The gecko id in the bundled manifest. Pre-consent matches on it as well as
    /// on the folder, so a copy that landed under a different folder name is still
    /// recognised as the one Aura ships.
    static let geckoID = "uBOLiteRedux@raymondhill.net"

    /// The blocker Aura shipped before, and the marker that says Aura is the one
    /// that put it there.
    private static let legacyMarkerKey = "extensions.bundled.ublock-origin"
    static let legacyFolderName = "ublock-origin"

    private static let log = Logger(subsystem: "com.aurabrowser.app", category: "extensions")

    /// Ids that load without the consent sheet. Installing Aura is the consent for
    /// what Aura itself puts in the profile.
    static let preConsentedIDs: Set<String> = [folderName, geckoID]

    static func isBundled(id: String, geckoID: String?) -> Bool {
        if preConsentedIDs.contains(id) { return true }
        guard let geckoID else { return false }
        return preConsentedIDs.contains(geckoID)
    }

    /// What one launch has to do about the bundled blocker. Pure, so the swap from
    /// uBlock Origin to uBO Lite is decided somewhere a test can reach.
    ///
    /// The old folder only goes when Aura is the one that unpacked it. A folder
    /// with no marker behind it was the user's own doing and stays.
    struct ReplacementPlan: Equatable {
        var removesLegacy: Bool
        var installsNew: Bool
    }

    static func replacementPlan(oldMarker: Bool, oldFolderExists: Bool, newMarker: Bool) -> ReplacementPlan {
        ReplacementPlan(removesLegacy: oldMarker && oldFolderExists, installsNew: !newMarker)
    }

    /// Unpacks anything bundled that this profile has not seen yet, and clears out
    /// the blocker it replaces. The caller's directory scan picks the result up
    /// like any other folder, so it arrives installed and enabled.
    ///
    /// The marker is set once the extension is on disk, and it is what stops a
    /// user who removed uBO Lite from finding it back tomorrow. A failed unpack
    /// leaves the marker alone: uBO Lite is the only ad blocker Aura ships, so one
    /// bad first launch must not cost the profile its blocking forever.
    static func installIfNeeded(into extensionsDirectory: URL) {
        let defaults = UserDefaults.standard
        let legacy = extensionsDirectory.appendingPathComponent(legacyFolderName, isDirectory: true)
        let plan = replacementPlan(
            oldMarker: defaults.bool(forKey: legacyMarkerKey),
            oldFolderExists: FileManager.default.fileExists(atPath: legacy.path),
            newMarker: defaults.bool(forKey: markerKey)
        )

        if plan.removesLegacy { removeLegacy(at: legacy) }
        // Full uBlock Origin only when the user asked for it, and here rather than from
        // the settings switch so the caller's directory listing picks the folder up in
        // the same pass. Which of the two then runs is `plan(for:)`'s call.
        if defaults.bool(forKey: SettingsStore.extensionFullAdBlockingKey) {
            unpackFullIfNeeded(into: extensionsDirectory)
        }
        guard plan.installsNew, let archive = archiveURL else { return }

        do {
            // nil means the folder is already there, which counts as installed.
            let installed = try unpack(archive, named: folderName, into: extensionsDirectory)
            defaults.set(true, forKey: markerKey)
            log.info("installed bundled \(installed?.lastPathComponent ?? folderName, privacy: .public)")
        } catch {
            log.error("bundled install failed, retrying next launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Takes the old blocker back out. Aura installed it, so removing it is not
    /// throwing away a choice the user made. The marker is cleared first, so a
    /// folder the user puts back under that name later is theirs and survives.
    private static func removeLegacy(at folder: URL) {
        UserDefaults.standard.set(false, forKey: legacyMarkerKey)
        try? FileManager.default.removeItem(at: folder)
        log.info("removed bundled uBlock Origin; uBlock Origin Lite replaces it")
        // The rest of the bookkeeping (the consent grant, the disabled flag, a
        // context that already loaded) belongs to the manager, which owns it. Off
        // the main actor here, so it goes through a hop.
        Task { @MainActor in
            ExtensionManager.shared.removeExtension(legacyFolderName)
        }
    }

    /// Unpacks one archive into `extensionsDirectory` under a fixed folder name.
    /// Returns nil when that folder is already there, so this never overwrites a
    /// copy the user has been running.
    @discardableResult
    static func unpack(_ archive: URL, named folderName: String, into extensionsDirectory: URL) throws -> URL? {
        let destination = extensionsDirectory.appendingPathComponent(folderName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }

        // ponytail: ~35 MB unzipped on the main actor, once per profile. Move it
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
    static var archiveURL: URL? {
        Bundle.main.url(forResource: folderName, withExtension: "xpi")
    }

    static var folderID: String { folderName }
}

// MARK: - Full uBlock Origin

extension BundledExtensions {
    /// The full uBlock Origin release Aura vendors, pinned to one upstream asset.
    ///
    /// AMO has deprecated the manifest-v2 listing, so the archive comes from uBO's own
    /// GitHub releases and travels inside the app bundle: the first time a user switches
    /// full blocking on there is nothing to download and nothing to trust at that moment.
    /// The hash is checked before the archive is unpacked, so a blob that was swapped in
    /// the app bundle (or a bad build) fails closed instead of installing an extension
    /// with `<all_urls>` that nobody vouched for.
    enum FullUBlockOrigin {
        static let version = "1.73.0"
        static let assetName = "uBlock0_1.73.0.firefox.signed.xpi"
        /// SHA-256 of that asset as published. `auraTests` checks the vendored copy
        /// against it, so CI fails if the blob and the pin drift apart.
        static let archiveSHA256 = "bccc51a773150af4af6e1fd62c7bfdeb7238b79ff2381b998fa9f2e38f64786a"
        /// The source offer GPL-3.0 asks for: this tag is the source of this binary.
        static let releaseURL = "https://github.com/gorhill/uBlock/releases/tag/1.73.0"

        /// Deliberately not `ublock-origin`: that folder name belongs to the copy Aura
        /// used to preinstall, and `installIfNeeded` deletes that one on sight.
        static let folderName = "ublock-origin-full"
        static let geckoID = "uBlock0@raymondhill.net"
        /// The file name inside `Aura.app/Contents/Resources`.
        static let resourceName = "ublock-origin"

        static var archiveURL: URL? {
            Bundle.main.url(forResource: resourceName, withExtension: "xpi")
        }

        /// The vendored archive, or nil when it is missing or is not the pinned build.
        static func verifiedArchiveURL() -> URL? {
            guard let url = archiveURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return nil
            }
            return sha256(data) == archiveSHA256 ? url : nil
        }

        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Set while Aura is the one holding uBO Lite back, so a user who switched Lite off
    /// themselves never finds it switched on again by the blocker swap.
    private static let litePausedKey = "extensions.bundled.lite.pausedForFull"

    /// Which of the two blockers a session runs. Never both: two filter engines on the
    /// same page means two rule sets fighting over the same requests, and uBO's own
    /// documentation says as much about running it next to another blocker.
    enum Blocker: Equatable {
        case lite
        case full
    }

    /// What the settings row is still waiting for, when it is waiting for something.
    enum Pending: Equatable {
        case none
        /// The consent sheet is queued and unanswered.
        case consent
        /// Consented; the injected bundle is only picked up at launch.
        case relaunch
    }

    /// Everything the choice depends on, gathered by the caller so the rule itself
    /// reads no globals and a test can state any of the states outright.
    struct BlockingInputs: Equatable {
        /// Settings > Privacy > Full ad blocking.
        var fullRequested: Bool
        /// Full uBO's folder is in the profile.
        var fullInstalled: Bool
        /// The user has seen the permissions the manifest asks for *now* and agreed to
        /// them: a record exists and its hash still matches. False either because there
        /// is no record, or because uBO's permission set changed since the approval.
        var fullConsented: Bool
        /// A consent record exists at all, whatever it now hashes to. Refusal is the
        /// absence of one (a decline clears it); recorded-but-stale means "ask again",
        /// which must not read as "the sheet was refused".
        var fullConsentRecorded: Bool
        /// It is switched off in the extensions list, which is also where a refused
        /// consent sheet leaves it.
        var fullDisabled: Bool
        /// Pages run on the injected-bundle pool in this session. Full uBO blocks
        /// through `webRequest` and blocks nothing at all without it.
        var bundleActive: Bool
        /// The startup health probe found the bundle stack broken this session.
        var unavailable: Bool
    }

    /// The outcome. The two settings are optional because most states must leave them
    /// exactly as the user set them; only the states below that name a value write one.
    struct BlockingPlan: Equatable {
        var activeBlocker: Blocker
        /// Unpack the vendored archive before anything else here takes effect.
        var installsFull: Bool
        /// What to write to `extensionRequestBlocking`, or nil to leave it alone.
        var requestBlocking: Bool?
        /// What to write to `extensionFullAdBlocking`, or nil to leave it alone.
        var fullRequested: Bool?
        var pending: Pending
    }

    /// The whole enable/disable rule, as a pure function.
    ///
    /// One line runs through all of it: uBO Lite keeps blocking until full uBO actually
    /// can. Unpacking, the consent sheet and the relaunch that loads the injected bundle
    /// each take time, and a browser with no blocker at all for a day is worse than one
    /// running the Lite build for a day.
    static func plan(for inputs: BlockingInputs) -> BlockingPlan {
        // A failed probe outranks the switch and writes neither setting: the next OS
        // build may put the stack back, and a preference the app cleared behind the
        // user's back would never turn itself on again.
        if inputs.unavailable {
            return BlockingPlan(
                activeBlocker: .lite, installsFull: false,
                requestBlocking: nil, fullRequested: nil, pending: .none
            )
        }
        guard inputs.fullRequested else {
            return BlockingPlan(
                activeBlocker: .lite, installsFull: false,
                requestBlocking: nil, fullRequested: nil, pending: .none
            )
        }
        // Installed, switched off, and no consent on record: the sheet was refused, or
        // the user switched full uBO off in the extensions list before it ever ran.
        // Nothing changes, and the switch goes back to where it was. A record that
        // exists but no longer matches is not this: that is an update asking for more,
        // and it falls through to the general branch as pending consent.
        if inputs.fullInstalled, !inputs.fullConsentRecorded, inputs.fullDisabled {
            return BlockingPlan(
                activeBlocker: .lite, installsFull: false,
                requestBlocking: false, fullRequested: false, pending: .none
            )
        }

        let ready = inputs.fullInstalled && inputs.fullConsented && inputs.bundleActive
        let pending: Pending = inputs.fullConsented ? (inputs.bundleActive ? .none : .relaunch) : .consent
        return BlockingPlan(
            activeBlocker: ready ? .full : .lite,
            installsFull: !inputs.fullInstalled,
            requestBlocking: true,
            fullRequested: nil,
            pending: ready ? .none : pending
        )
    }

    /// The state `plan(for:)` runs on, read off the settings store, the extension list
    /// and the disk.
    ///
    /// `installedExtensions` is empty until the scan adopts its rows, so the folder on
    /// disk and the stored disabled ids are what answer before that point.
    @MainActor
    static func blockingInputs() -> BlockingInputs {
        let manager = ExtensionManager.shared
        let settings = SettingsStore.shared
        let id = FullUBlockOrigin.folderName
        let row = manager.installedExtensions.first { $0.id == id }
        let folder = manager.extensionsDirectory.appendingPathComponent(id, isDirectory: true)

        return BlockingInputs(
            fullRequested: settings.extensionFullAdBlocking,
            fullInstalled: row != nil || FileManager.default.fileExists(atPath: folder.path),
            fullConsented: fullConsentStands(for: folder),
            fullConsentRecorded: settings.extensionConsent[id] != nil,
            fullDisabled: row.map { !$0.isEnabled } ?? manager.disabledIDs.contains(id),
            bundleActive: AuraWebBundle.isEnabled,
            unavailable: settings.requestBlockingUnavailable
        )
    }

    /// Consent as the loader will actually read it: a record for the same permission
    /// set the manifest asks for now. A bare "a record exists" check disagreed with
    /// `ExtensionConsent.decision` whenever the stored hash had drifted, and the plan
    /// then paused uBO Lite for a full uBO the loader was about to park on the consent
    /// queue — a session with no blocker at all and every page on the fragile pool.
    @MainActor
    private static func fullConsentStands(for folder: URL) -> Bool {
        guard let record = SettingsStore.shared.extensionConsent[FullUBlockOrigin.folderName] else {
            return false
        }
        let permissions = ExtensionManager.requestedPermissions(at: folder)
        return record.permissionsHash == ExtensionConsent.permissionsHash(permissions)
    }

    /// True while `applyBlockingPlan` is switching rows itself, so the manager's
    /// `setEnabled` reporting back through `rowDidChange` cannot recurse.
    @MainActor
    private static var isApplyingPlan = false

    /// A row in the extensions list was flipped by hand, or a consent sheet was
    /// answered. For the two bundled blockers that is an answer the plan has to hear —
    /// a full uBO re-enabled during its pending relaunch would otherwise run alongside
    /// uBO Lite, and a consent declined outside Settings left the Privacy switch on.
    /// Everything else is none of the plan's business.
    ///
    /// A full uBO row whose state disagrees with the Privacy switch answers the
    /// switch, the same way uninstalling it does: without this, the plan (for which
    /// the switch is the source of truth) would flip the row straight back under the
    /// user's click. Rows turned *on* always answer it — an unconsented one flipped on
    /// is asking for the feature, and the plan's consent gate takes it from there.
    /// Turned *off* without a consent record is the refused-sheet state, which the
    /// plan reads off the row itself, so that falls through.
    @MainActor
    static func rowDidChange(id: String) {
        guard !isApplyingPlan else { return }
        if id == FullUBlockOrigin.folderName {
            let enabled = ExtensionManager.shared.installedExtensions
                .first { $0.id == id }?.isEnabled == true
            if SettingsStore.shared.extensionFullAdBlocking != enabled,
               enabled || SettingsStore.shared.extensionConsent[id] != nil {
                setFullBlocking(enabled)
                return
            }
            applyBlockingPlan()
            return
        }
        if id == folderName { applyBlockingPlan() }
    }

    /// Runs the plan and makes it true. Idempotent, and called from the places the
    /// answer can change: the settings switch, the launch scan, a hand-flipped blocker
    /// row, and the health probe giving up on the injected bundle.
    @MainActor
    static func applyBlockingPlan() {
        isApplyingPlan = true
        defer { isApplyingPlan = false }
        let plan = plan(for: blockingInputs())
        let settings = SettingsStore.shared

        if let fullRequested = plan.fullRequested, fullRequested != settings.extensionFullAdBlocking {
            settings.extensionFullAdBlocking = fullRequested
        }
        if let requestBlocking = plan.requestBlocking, requestBlocking != settings.extensionRequestBlocking {
            settings.extensionRequestBlocking = requestBlocking
        }
        if plan.installsFull { installFull() }
        apply(plan)
    }

    /// The settings switch. Everything past the stored preference is the plan's job, so
    /// the switch and the launch path cannot disagree about what "on" means.
    ///
    /// Switching off also switches the injected bundle off, which is the only way to get
    /// the ordinary WebContent service back. An add-on other than uBO that wanted
    /// blocking `webRequest` needs its own switch turned on again after this.
    @MainActor
    static func setFullBlocking(_ enabled: Bool) {
        let settings = SettingsStore.shared
        settings.extensionFullAdBlocking = enabled
        if !enabled { settings.extensionRequestBlocking = false }
        applyBlockingPlan()
    }

    /// Switches the two blockers over.
    ///
    /// Before the scan has adopted its rows there is nothing to call `setEnabled` on, and
    /// `disabledIDs` is what decides whether the row about to be built loads at all. So
    /// the same decision is written either through the manager or straight into that set,
    /// and the launch path never ends up loading the blocker it just switched off.
    @MainActor
    private static func apply(_ plan: BlockingPlan) {
        let manager = ExtensionManager.shared
        // While a consent sheet is unanswered, full uBO's own switch belongs to that
        // sheet: declining turns it off, approving turns it on and loads it.
        if plan.pending != .consent {
            setEnabled(plan.activeBlocker == .full, id: FullUBlockOrigin.folderName, manager: manager)
        } else if SettingsStore.shared.extensionConsent[FullUBlockOrigin.folderName] != nil {
            // Pending consent with a record on file is a stale approval — uBO's
            // permission set changed — not an unanswered first sheet. The row was
            // parked off by an earlier plan run, and it has to come back on for the
            // loader to reach the consent gate and queue the re-prompt at all. uBO
            // Lite is still the active blocker while the sheet waits.
            setEnabled(true, id: FullUBlockOrigin.folderName, manager: manager)
        }

        let defaults = UserDefaults.standard
        switch plan.activeBlocker {
        case .full:
            let liteEnabled = manager.installedExtensions.first { $0.id == folderName }?.isEnabled
                ?? !manager.disabledIDs.contains(folderName)
            guard liteEnabled else { return }
            defaults.set(true, forKey: litePausedKey)
            setEnabled(false, id: folderName, manager: manager)
        case .lite:
            guard defaults.bool(forKey: litePausedKey) else { return }
            defaults.set(false, forKey: litePausedKey)
            setEnabled(true, id: folderName, manager: manager)
        }
    }

    @MainActor
    private static func setEnabled(_ enabled: Bool, id: String, manager: ExtensionManager) {
        if let row = manager.installedExtensions.first(where: { $0.id == id }) {
            guard row.isEnabled != enabled else { return }
            manager.setEnabled(enabled, for: id)
            return
        }
        // Nothing on disk and no row: writing the id into `disabledIDs` here would
        // outlive the extension and come back to switch off a later reinstall.
        let folder = manager.extensionsDirectory.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }

        var ids = manager.disabledIDs
        if enabled {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        guard ids != manager.disabledIDs else { return }
        manager.disabledIDs = ids
    }

    /// Unpacks the vendored archive mid-session and hands the folder to the ordinary
    /// install path, which is what puts the consent sheet on screen. Full uBO is not
    /// pre-consented like the Lite build: it asks for `<all_urls>` and switching it on
    /// changes how every page in the browser is rendered.
    ///
    /// Off the main actor because ~17 MB of it lands on disk, then back for the register.
    @MainActor
    private static func installFull() {
        let directory = ExtensionManager.shared.extensionsDirectory
        Task.detached(priority: .userInitiated) {
            guard let folder = unpackFullIfNeeded(into: directory) else { return }
            await MainActor.run {
                ExtensionManager.shared.registerExtension(
                    at: folder,
                    source: .archive(FullUBlockOrigin.assetName)
                )
            }
        }
    }

    /// Puts full uBO's folder in the profile, hash-checked, and returns it. An existing
    /// folder at the pinned version is returned untouched, so this is safe to call on
    /// every launch. A folder at any other version (or with an unreadable manifest) is
    /// replaced: the name is Aura's own vendoring, never a hand install, so what is
    /// there came from an older build or a broken unpack, and loading it forever is how
    /// a stale uBO survives every update. Its user data lives in WebKit's storage keyed
    /// by the extension id, not in the folder, so nothing of the user's goes with it.
    ///
    /// `nonisolated` on purpose: the launch path calls it from inside the extension scan,
    /// before the directory listing, so the folder is picked up by that same scan.
    /// Serializes `unpackFullIfNeeded`: the background scan, `finishScanNow` and the
    /// settings switch's install can all reach it, and with the stale-version delete
    /// above a second caller mid-unpack would race the first destructively. The loser
    /// blocks briefly, then returns through the version fast path.
    private static let unpackLock = NSLock()

    @discardableResult
    static func unpackFullIfNeeded(into extensionsDirectory: URL) -> URL? {
        unpackLock.lock()
        defer { unpackLock.unlock() }

        let destination = extensionsDirectory
            .appendingPathComponent(FullUBlockOrigin.folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            if installedVersion(at: destination) == FullUBlockOrigin.version { return destination }
            log.info("replacing full uBlock Origin at a stale or unreadable version")
            try? FileManager.default.removeItem(at: destination)
        }

        guard let archive = FullUBlockOrigin.verifiedArchiveURL() else {
            log.error("full uBlock Origin archive missing or does not match the pinned hash")
            return nil
        }
        do {
            return try unpack(archive, named: FullUBlockOrigin.folderName, into: extensionsDirectory)
        } catch {
            log.error("full uBlock Origin unpack failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The manifest version of the copy on disk, or nil when there is no readable one.
    /// The shim patch never touches `version`, so this reads the same either way.
    private static func installedVersion(at folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return manifest["version"] as? String
    }
}
