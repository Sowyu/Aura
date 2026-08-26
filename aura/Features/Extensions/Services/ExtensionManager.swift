import AppKit
import Foundation
import os
@preconcurrency import WebKit

/// One installed extension as shown in Settings. Mirrored from disk so the
/// list renders even before WebKit finishes loading the extension (or on
/// systems where WKWebExtension is unavailable).
struct InstalledExtension: Identifiable, Equatable {
    let id: String
    let directoryURL: URL
    var displayName: String
    /// The manifest's own description, translated. Shown on the consent sheet, which
    /// is where a user is deciding about an extension they may not know.
    var displayDescription: String?
    var displayVersion: String?
    /// The manifest's gecko id, which is the same string AMO reports as a guid.
    /// Nil for extensions whose manifest declares none (Chrome-only ones).
    var geckoID: String?
    var isEnabled: Bool
    var icon: NSImage?
    var loadError: String?
}

/// The manifest fields the browser shows, already translated out of `_locales`.
struct ParsedManifest {
    var name: String?
    var description: String?
    var version: String?
    var geckoID: String?
}

/// One extension as the background scan found it: the disk reads, the shim patch and
/// the manifest parse are already done by the time this reaches the main actor.
struct ScannedExtension: Sendable {
    let id: String
    let directoryURL: URL
    let displayName: String?
    let displayDescription: String?
    let displayVersion: String?
    let geckoID: String?
    let loadError: String?
}

/// Weak handle on a toolbar button so a closed window's view can be released.
private final class WeakAnchor {
    weak var value: NSView?

    init(_ value: NSView) {
        self.value = value
    }
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
/// Extensions run in every window. Private ones are hidden from them until the user
/// grants "run in private windows" per extension, which is Firefox's rule. Installing
/// grants every permission the manifest asks for, so nothing loads before
/// `ExtensionConsent` confirms the user saw that list and agreed to it.
@Observable
@MainActor
final class ExtensionManager {
    static let shared = ExtensionManager()

    /// Internal setter rather than private: the extensions in the sibling files
    /// (`+Loading`, `+Updates`) are this class and write rows through it.
    var installedExtensions: [InstalledExtension] = []

    /// Installs waiting on the user. `ExtensionConsentPrompt` puts the front one on
    /// screen; until it is answered the extension sits on disk, unloaded. Internal
    /// setter for the same reason as `installedExtensions`.
    var pendingConsent: [ExtensionConsentRequest] = []

    /// Bumped whenever WebKit updates an action (icon, badge, enabled state) so
    /// the toolbar redraws. The values themselves are pulled on demand.
    private(set) var actionRevision = 0

    /// Last toolbar button each extension's popup was anchored to, keyed by
    /// extension id. Weak: the button dies with its window.
    @ObservationIgnored private var actionAnchors: [String: WeakAnchor] = [:]
    @ObservationIgnored private var hasWindowObservers = false

    static var isSupported: Bool {
        guard #available(macOS 15.4, *) else { return false }
        return true
    }

    private static let disabledIDsKey = "extensions.disabledIDs"
    private static let consentGrandfatheredKey = "extensions.consent.grandfathered"
    static let awaitingConsentNote = "Not loaded: waiting for you to review what it can do."

    static let log = Logger(subsystem: "com.aurabrowser.app", category: "extensions")

    /// Whether the scan and installs rewrite extensions for the shim. Always, now.
    ///
    /// The shim carries two unrelated things: the blocking-`webRequest` bridge, which
    /// only means anything while the injected bundle runs, and the relay that carries
    /// `runtime.connect`/`runtime.sendMessage` from an extension's own pages to its
    /// background page, which WebKit delivers nowhere on its own (see
    /// `ExtensionMessageRelay`). Every extension with a popup needs the second one
    /// whatever the user decided about ad blocking, and gating the patch on the
    /// request-blocking setting is what left every popup in the default configuration
    /// talking to a background page that never heard it: a password manager spinning
    /// forever, a blocker's panel blank.
    ///
    /// Nothing is rewritten needlessly: `ExtensionShim.apply` leaves an extension with
    /// neither blocking `webRequest` nor pages of its own exactly as downloaded, and
    /// consent is hashed over the pristine manifest, so a patch drifts no permissions.
    var shimPatchingEnabled: Bool { true }

    /// Ids whose update is downloading right now, so the row can say so. Stored here,
    /// and internal rather than private, because `ExtensionManager+Updates` is an
    /// extension: it can hold no state of its own and writes through this.
    var updatingIDs: Set<String> = []

    /// The local key-down monitor `ExtensionManager+Commands` installs, for the same
    /// reason.
    @ObservationIgnored var commandMonitor: Any?

    /// One observer per loaded context, keyed by extension id. Internal because
    /// `ExtensionManager+Loading` registers and drops them.
    @ObservationIgnored var errorObservers: [String: NSObjectProtocol] = [:]

    /// One surface shows a given consent request, not every open window: the store tab
    /// and the settings section both watch the queue, and two copies of the same sheet
    /// would let the user answer one and stare at the other.
    @ObservationIgnored var presentingConsent: Set<String> = []

    /// Internal rather than private: `isLoadingExtensions` reads both.
    @ObservationIgnored var hasStarted = false
    @ObservationIgnored var hasScanned = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored var updateCheckTask: Task<Void, Never>?
    /// AnyObject storage because WKWebExtensionController's type is 15.4+;
    /// typed access goes through the `engine` accessor below.
    @ObservationIgnored private var engineStorage: AnyObject?

    /// Internal rather than private: `ExtensionManager+Loading` loads through it.
    @available(macOS 15.4, *)
    var engine: ExtensionEngine {
        if let engine = engineStorage as? ExtensionEngine {
            return engine
        }
        let engine = ExtensionEngine()
        engineStorage = engine
        return engine
    }

    /// The engine only if something already built it. Lifecycle hooks use this so
    /// a profile with no extensions never spins up a `WKWebExtensionController`.
    /// Not private: the tests read it to prove nothing built one behind them.
    @available(macOS 15.4, *)
    var loadedEngine: ExtensionEngine? {
        engineStorage as? ExtensionEngine
    }

    var extensionsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Aura/Extensions", isDirectory: true)
    }

    /// Internal rather than private: `ExtensionManager+Loading` reads it while building
    /// a row.
    var disabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.disabledIDsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.disabledIDsKey) }
    }

    // MARK: - Wiring

    /// Called from BrowserPage while building its WKWebViewConfiguration.
    ///
    /// Private configurations get the controller as well. What keeps an extension out of
    /// private browsing is `hasAccessToPrivateData` on its own context, not withholding
    /// the controller from the web view: without the controller there, an extension the
    /// user did allow into private windows could neither block nor inject there.
    /// `isPrivate` stays in the signature because the caller knows it and a future
    /// per-store decision belongs here rather than at the call site.
    func attach(to configuration: WKWebViewConfiguration, isPrivate: Bool) {
        guard #available(macOS 15.4, *) else { return }
        configuration.webExtensionController = engine.controller
        start()
    }

    /// The configuration a tab has to be built on to show `url` when it is an extension's
    /// own page (its dashboard, options page or any other file of its own); nil when it
    /// is not one, or its extension has not loaded yet.
    ///
    /// WebKit serves an extension page as a main frame only to a web view whose
    /// configuration names that extension (`_requiredWebExtensionBaseURL`, which only
    /// `WKWebExtensionContext.webViewConfiguration` sets); any other web view gets
    /// `NSURLErrorResourceUnavailable`, which is what put Aura's error page on every
    /// extension page opened in a tab. And a web view built that way shows nothing else,
    /// so a tab crossing that line in either direction swaps web views (`Tab.rehost`).
    func pageConfiguration(hosting url: URL) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *), url.scheme?.lowercased() == ExtensionOrigin.scheme,
              let context = loadedEngine?.controller.extensionContext(for: url), context.isLoaded
        else { return nil }
        return context.webViewConfiguration
    }

    // MARK: - Private windows

    /// True when `id` may see private windows, tabs and cookies. Default off: an
    /// extension is installed for normal browsing, and private browsing is a separate
    /// decision the user makes once per extension.
    func runsInPrivateWindows(_ id: String) -> Bool {
        SettingsStore.shared.extensionPrivateWindowGrants.contains(id)
    }

    /// Grants or revokes private-window access. The live context is updated too, so the
    /// change applies to the next page load rather than the next launch.
    func setRunsInPrivateWindows(_ enabled: Bool, for id: String) {
        var grants = SettingsStore.shared.extensionPrivateWindowGrants
        if enabled {
            grants.insert(id)
        } else {
            grants.remove(id)
        }
        SettingsStore.shared.extensionPrivateWindowGrants = grants
        if #available(macOS 15.4, *) {
            loadedEngine?.setPrivateAccess(enabled, for: id)
        }
    }

    /// Scans the extensions directory and loads every enabled extension.
    ///
    /// The scan runs off the main actor. `attach(to:)` calls this from the first
    /// `BrowserPage.init`, and reading every extension folder, parsing its manifest
    /// and rewriting it for the shim used to happen there, before the first page
    /// could start loading. Only `engine.controller` is needed synchronously.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        if #available(macOS 15.4, *) {
            // Clears any state file left behind by the last run, before a page
            // can make the injected bundle act on it.
            WebRequestBroker.prepare()
        }

        let directory = extensionsDirectory
        let patchesShim = shimPatchingEnabled
        scanTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                ExtensionManager.scan(directory: directory, patchesShim: patchesShim)
            }.value
            guard !Task.isCancelled else { return }
            self?.adoptScan(found)
        }
    }

    /// Installing needs the finished list to recognise a duplicate, so an install that
    /// beats the background scan finishes the scan itself first. The work is idempotent:
    /// whichever of the two lands first wins and the other is dropped.
    private func finishScanNow() {
        guard hasStarted, !hasScanned else { return }
        scanTask?.cancel()
        adoptScan(Self.scan(directory: extensionsDirectory, patchesShim: shimPatchingEnabled))
    }

    private func adoptScan(_ found: [ScannedExtension]) {
        guard !hasScanned else { return }
        hasScanned = true
        scanTask = nil
        grandfatherExistingConsent(found)
        // Before the plan: `fullConsentStands` reads these records, and an
        // unmigrated one would park full uBO for the launch.
        migrateShimPatchedConsent(found)
        // Which of the two bundled blockers this launch runs, before the rows are built:
        // `disabledIDs` is what decides whether `register` loads one of them at all.
        BundledExtensions.applyBlockingPlan()
        for entry in found { register(entry) }
        checkForUpdates()
    }

    /// Consent used to be hashed over the shim-patched manifest, which carries the
    /// shim's own `nativeMessaging`. Now that it is hashed over the pristine one, a
    /// record written under the old rule would drift and re-prompt for permissions the
    /// user already answered. Only a record matching the pristine list plus exactly
    /// that one entry is rewritten — that is precisely the list the old sheet showed —
    /// so a genuine permission change still comes back through the sheet. Self-
    /// limiting: after the rewrite nothing matches the old shape any more.
    private func migrateShimPatchedConsent(_ found: [ScannedExtension]) {
        var consent = SettingsStore.shared.extensionConsent
        var changed = false
        for entry in found {
            guard let record = consent[entry.id] else { continue }
            let pristine = Self.requestedPermissions(at: entry.directoryURL)
            let oldScheme = ExtensionConsent.permissionsHash(pristine + ["nativeMessaging"])
            let newScheme = ExtensionConsent.permissionsHash(pristine)
            guard record.permissionsHash == oldScheme, oldScheme != newScheme else { continue }
            consent[entry.id] = ExtensionConsentRecord(version: record.version, permissionsHash: newScheme)
            changed = true
        }
        if changed { SettingsStore.shared.extensionConsent = consent }
    }

    /// Extensions already on disk when the consent gate shipped were installed under the
    /// old rule, where installing granted everything without asking. Prompting for them
    /// at launch would ask about choices the user cannot remember making, so they are
    /// recorded as consented once. Anything arriving after that goes through the sheet,
    /// including a folder dropped straight into the profile.
    private func grandfatherExistingConsent(_ found: [ScannedExtension]) {
        guard !UserDefaults.standard.bool(forKey: Self.consentGrandfatheredKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.consentGrandfatheredKey)

        var consent = SettingsStore.shared.extensionConsent
        for entry in found where consent[entry.id] == nil {
            let request = ExtensionConsentRequest(
                id: entry.id,
                displayName: entry.displayName ?? entry.id,
                displayDescription: entry.displayDescription,
                version: entry.displayVersion,
                source: .folder(entry.directoryURL.lastPathComponent),
                permissions: Self.requestedPermissions(at: entry.directoryURL)
            )
            consent[entry.id] = ExtensionConsent.record(for: request)
        }
        SettingsStore.shared.extensionConsent = consent
    }

    /// Everything that touches disk, off the main actor: the folder listing, the shim
    /// patch and the manifest parse.
    nonisolated static func scan(directory: URL, patchesShim: Bool) -> [ScannedExtension] {
        let fileManager = FileManager.default
        BundledExtensions.installIfNeeded(into: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { prepare(at: $0, patchesShim: patchesShim) }
    }

    nonisolated static func prepare(at directory: URL, patchesShim: Bool) -> ScannedExtension {
        // Before the manifest is read: patching rewrites it, and a shim version
        // bump has to take effect on the next launch rather than the next
        // install.
        var shimError: String?
        if patchesShim {
            do {
                try ExtensionShim.apply(at: directory)
            } catch {
                shimError = error.localizedDescription
            }
        }

        let manifest = Self.parseManifest(at: directory.appendingPathComponent("manifest.json"))
        return ScannedExtension(
            id: directory.lastPathComponent,
            directoryURL: directory,
            displayName: manifest.name,
            displayDescription: manifest.description,
            displayVersion: manifest.version,
            geckoID: manifest.geckoID,
            loadError: shimError ?? Self.compatibilityNote(at: directory)
        )
    }

    // MARK: - Toolbar actions

    /// Clicking an extension's toolbar icon. WebKit decides what happens next:
    /// a popup goes through `presentActionPopup`, otherwise the extension's
    /// `action.onClicked` event fires.
    func performAction(extensionID: String, anchor: NSView) {
        guard #available(macOS 15.4, *) else { return }
        actionAnchors[extensionID] = WeakAnchor(anchor)
        guard let context = engine.context(for: extensionID) else {
            // The icon renders from the installed row, so a click can land while no
            // context exists: consent pending, a load error, or a load still in
            // flight. Silence here looks like a dead button, so at least the log
            // says which of those it was.
            let reason = installedExtensions.first { $0.id == extensionID }?.loadError ?? "still loading"
            Self.log.error("""
            toolbar action ignored for \(extensionID, privacy: .public): \
            \(reason, privacy: .public)
            """)
            return
        }
        context.performAction(for: currentTabAdapter(for: extensionID))
    }

    /// The action's current icon, which follows `browser.action.setIcon` and
    /// falls back to the manifest icon. Nil until the extension has loaded.
    func actionIcon(for extensionID: String, size: CGSize) -> NSImage? {
        guard #available(macOS 15.4, *), let context = loadedEngine?.context(for: extensionID) else { return nil }
        return context.action(for: currentTabAdapter(for: extensionID))?.icon(for: size)
    }

    func actionBadgeText(for extensionID: String) -> String? {
        guard #available(macOS 15.4, *), let context = loadedEngine?.context(for: extensionID) else { return nil }
        let text = context.action(for: currentTabAdapter(for: extensionID))?.badgeText
        return (text?.isEmpty ?? true) ? nil : text
    }

    func actionDidUpdate() {
        actionRevision &+= 1
    }

    func popupAnchor(for extensionID: String) -> NSView? {
        if let view = actionAnchors[extensionID]?.value, view.window != nil {
            return view
        }
        // `browser.action.openPopup()` can fire without a click; centre it.
        return NSApp.keyWindow?.contentView
    }

    /// The tab an action applies to, from this extension's point of view. An extension
    /// with no private-window grant gets no tab at all in a private window rather than
    /// the wrong one: its popup still opens, it just has nothing to read.
    @available(macOS 15.4, *)
    private func currentTabAdapter(for extensionID: String) -> ExtensionTabAdapter? {
        guard let window = ExtensionWindowAdapter.focusedAdapter(),
              let tab = window.tabManager?.activeTab,
              ExtensionWindowAdapter.showsTabs(
                  inPrivateWindow: window.isPrivateWindow,
                  contextHasPrivateAccess: runsInPrivateWindows(extensionID)
              )
        else { return nil }
        return ExtensionTabAdapter.adapter(for: tab)
    }

    // MARK: - Window and tab lifecycle

    /// Called once per browser window as it appears, private ones included: an extension
    /// with a private-window grant has to be told they exist, and WebKit hides them from
    /// everything else.
    func windowDidOpen(_ window: NSWindow, tabManager: TabManager, isPrivate: Bool = false) {
        guard #available(macOS 15.4, *) else { return }
        // Otherwise nothing runs until the first web view is built: a launch onto
        // aura://settings or aura://home showed a toolbar with no extension buttons and
        // a blocker that had not loaded, and the bundled blockers' bookkeeping (which
        // blocker is paused for which) only reconciled once the user opened a page.
        start()
        startWindowObservers()
        let adapter = ExtensionWindowAdapter.adapter(for: window, tabManager: tabManager, isPrivate: isPrivate)
        loadedEngine?.controller.didOpenWindow(adapter)
        if window.isKeyWindow {
            loadedEngine?.controller.didFocusWindow(adapter)
        }
    }

    /// True when some extension has been let into private browsing.
    ///
    /// Nothing about a private tab is reported while this is false. WebKit works out a
    /// tab's privacy from its web view's data store, and a private tab that has no web
    /// view yet (hibernated, or sitting on an aura:// page) would look like an ordinary
    /// one to every extension. The window it belongs to reports itself as private
    /// either way, so a granted extension still finds it.
    private var anyExtensionSeesPrivateTabs: Bool {
        !SettingsStore.shared.extensionPrivateWindowGrants.isEmpty
    }

    private func reportsTab(_ tab: Tab) -> Bool {
        !tab.isPrivate || anyExtensionSeesPrivateTabs
    }

    func tabDidOpen(_ tab: Tab) {
        guard #available(macOS 15.4, *), reportsTab(tab), let engine = loadedEngine else { return }
        engine.controller.didOpenTab(ExtensionTabAdapter.adapter(for: tab))
    }

    /// Not gated on the private rule above: reporting a close only ever takes knowledge
    /// away, and a tab that was reported while a grant existed has to be closed even if
    /// the grant went away since.
    func tabDidClose(_ tab: Tab) {
        guard #available(macOS 15.4, *),
              let adapter = ExtensionTabAdapter.discardAdapter(for: tab)
        else { return }
        loadedEngine?.controller.didCloseTab(adapter, windowIsClosing: false)
    }

    func tabDidActivate(_ tab: Tab, previous: Tab?) {
        guard #available(macOS 15.4, *), reportsTab(tab), let engine = loadedEngine else { return }
        let adapter = ExtensionTabAdapter.adapter(for: tab)
        let previousAdapter = previous.flatMap { $0.id == tab.id ? nil : ExtensionTabAdapter.adapter(for: $0) }
        // A tab from another space, or one back from hibernation, may never have been
        // reported: WebKit ignores the open when it already knows the tab, and the
        // property change is what an extension's own tab table (DuckDuckGo) needs.
        engine.controller.didOpenTab(adapter)
        engine.controller.didChangeTabProperties([.URL, .title, .loading], for: adapter)
        engine.controller.didActivateTab(adapter, previousActiveTab: previousAdapter)
        engine.controller.didSelectTabs([adapter])
    }

    /// One hook for url/title/loading, called from the single place navigation
    /// updates land (`TabBrowserPageDelegate`).
    func tabNavigationDidChange(_ tab: Tab) {
        guard #available(macOS 15.4, *), reportsTab(tab), let engine = loadedEngine else { return }
        engine.controller.didChangeTabProperties(
            [.loading, .title, .URL],
            for: ExtensionTabAdapter.adapter(for: tab)
        )
    }

    /// Registered once, application-wide: per-window observers would fire N times
    /// for the same window because every `OraRoot` listens on `object: nil`.
    @available(macOS 15.4, *)
    private func startWindowObservers() {
        guard !hasWindowObservers else { return }
        hasWindowObservers = true
        let center = NotificationCenter.default

        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      let adapter = ExtensionWindowAdapter.adapter(for: window)
                else { return }
                ExtensionManager.shared.loadedEngine?.controller.didFocusWindow(adapter)
            }
        }

        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow,
                      let adapter = ExtensionWindowAdapter.discardAdapter(for: window)
                else { return }
                ExtensionManager.shared.loadedEngine?.controller.didCloseWindow(adapter)
            }
        }
    }

    // MARK: - Install / remove / toggle

    /// Copies an unpacked extension folder into the extensions directory and loads it.
    /// `source` is only what the consent sheet names as the origin of the files.
    func installExtension(from sourceURL: URL, source: ExtensionInstallSource? = nil) throws {
        start()
        finishScanNow()

        let manifestURL = sourceURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExtensionInstallError.missingManifest
        }

        let manifest = Self.parseManifest(at: manifestURL)
        let name = manifest.name ?? sourceURL.lastPathComponent
        // Same guid-first rule the store badge uses, so a renamed or re-translated
        // copy of an add-on that is already here still counts as a duplicate.
        let isDuplicate = installedExtensions.contains { installed in
            if let geckoID = manifest.geckoID, let installedID = installed.geckoID {
                return geckoID == installedID
            }
            return installed.displayName == name
        }
        if isDuplicate {
            throw ExtensionInstallError.alreadyInstalled(name)
        }

        let id = Self.sanitizedID(from: name)
        let destination = extensionsDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        registerExtension(at: destination, source: source ?? .folder(sourceURL.lastPathComponent))
    }

    /// Downloads a Firefox add-on's .xpi from addons.mozilla.org, unpacks it,
    /// and installs it like any other unpacked extension.
    func installFirefoxAddon(_ addon: FirefoxAddon) async throws {
        guard let downloadURL = addon.downloadURL else {
            throw FirefoxAddonStoreError.missingDownload
        }
        start()
        finishScanNow()

        let archive = try await FirefoxAddonStore.shared.downloadXPI(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: archive) }
        try installArchive(at: archive, source: Self.installSource(for: addon))
    }

    /// What the consent sheet calls an AMO install. The guid is the id the add-on runs
    /// under, so it is what identifies the listing; the slug is the fallback for
    /// payloads that predate the field.
    static func installSource(for addon: FirefoxAddon) -> ExtensionInstallSource {
        .addonStore(addon.guid ?? addon.slug)
    }

    /// A folder holding manifest.json, or a packaged extension (.xpi, .zip, .crx).
    func installExtension(fromFile url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try installExtension(from: url, source: .folder(url.lastPathComponent))
            return
        }
        start()
        finishScanNow()
        let source = ExtensionInstallSource.archive(url.lastPathComponent)
        guard url.pathExtension.lowercased() == "crx" else {
            try installArchive(at: url, source: source)
            return
        }
        // Chrome packs the same zip behind a signature header; drop the header.
        let zipURL = try XPIUnpacker.zipFromCRX(url)
        defer { try? FileManager.default.removeItem(at: zipURL) }
        try installArchive(at: zipURL, source: source)
    }

    /// Unpacks a zip-shaped archive into a temporary folder and installs what it holds.
    private func installArchive(at archive: URL, source: ExtensionInstallSource) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-addon-unpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try XPIUnpacker.unpack(archive, to: staging)
        guard let root = XPIUnpacker.manifestRoot(in: staging) else {
            throw ExtensionInstallError.missingManifest
        }
        try installExtension(from: root, source: source)
    }

    /// The installed entry an AMO listing produced.
    func installedExtension(matching addon: FirefoxAddon) -> InstalledExtension? {
        installedExtensions.first { Self.matches(addon, $0) }
    }

    /// Same add-on or not. The guid is the identity WebExtensions actually use, so it
    /// wins whenever both sides have one: display names are translated per locale and
    /// two unrelated add-ons are free to share one. Names are the last resort, for
    /// Chrome-shaped manifests that declare no gecko id.
    static func matches(_ addon: FirefoxAddon, _ installed: InstalledExtension) -> Bool {
        if let guid = addon.guid, let geckoID = installed.geckoID {
            return guid == geckoID
        }
        return installed.displayName.caseInsensitiveCompare(addon.name) == .orderedSame
    }

    /// The extension's own options page, when it declares one. Nil until it has loaded.
    func optionsPageURL(for id: String) -> URL? {
        guard #available(macOS 15.4, *) else { return nil }
        return loadedEngine?.context(for: id)?.optionsPageURL
    }

    /// Removes every trace of an extension: its stored data, its files, and the records
    /// Aura keeps about it.
    ///
    /// The data lives in WebKit's own directory keyed by `uniqueIdentifier`, which is
    /// this folder id, so deleting the folder never touched it: a reinstall of the same
    /// add-on picked up the storage of the copy the user had just thrown away. Aura's
    /// own records (consent, the private-window grant, command bindings, the update
    /// offer) go for the same reason.
    func removeExtension(_ id: String) {
        stopObservingErrors(of: id)
        let index = installedExtensions.firstIndex { $0.id == id }
        if #available(macOS 15.4, *) {
            // Not `engine`: that accessor builds a WKWebExtensionController on
            // demand, and removing an extension that never loaded would spin
            // one up only to unload nothing from it.
            loadedEngine?.unload(id: id)
            // Something that was never installed has no data to purge either, which is
            // what keeps that same accessor out of this path.
            if index != nil { purgeStoredData(for: id) }
        }
        if let index {
            try? FileManager.default.removeItem(at: installedExtensions[index].directoryURL)
            installedExtensions.remove(at: index)
        }
        disabledIDs.remove(id)
        pendingConsent.removeAll { $0.id == id }
        // Removing is the one way to forget a grant: a reinstall of the same id later is
        // a fresh decision, and the sheet has to come back for it.
        SettingsStore.shared.extensionConsent[id] = nil
        setRunsInPrivateWindows(false, for: id)
        SettingsStore.shared.extensionAvailableUpdates[id] = nil
        CustomKeyboardShortcutManager.shared.removeShortcuts(
            withPrefix: ExtensionCommandShortcut.idPrefix(forExtension: id)
        )
        // Uninstalling full uBlock Origin answers the switch that installed it too,
        // or the blocker plan would unpack it again on the next launch.
        if id == BundledExtensions.FullUBlockOrigin.folderName, SettingsStore.shared.extensionFullAdBlocking {
            BundledExtensions.setFullBlocking(false)
        }
    }

    /// Drops `browser.storage` (local, session and sync) for one extension.
    ///
    /// By id rather than by context: an extension that is disabled has no context to
    /// ask, and its data outlives the session all the same.
    @available(macOS 15.4, *)
    private func purgeStoredData(for id: String) {
        let controller = engine.controller
        Task { @MainActor in
            let types = WKWebExtensionController.allExtensionDataTypes
            let records = await controller.dataRecords(ofTypes: types)
                .filter { $0.uniqueIdentifier == id }
            guard !records.isEmpty else { return }
            await controller.removeData(ofTypes: types, from: records)
        }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = installedExtensions.firstIndex(where: { $0.id == id }) else { return }
        installedExtensions[index].isEnabled = enabled
        installedExtensions[index].loadError = nil
        // Flipping one of the two bundled blockers by hand has to go back through the
        // plan, or a full-uBO row re-enabled while its relaunch is still pending runs
        // next to uBO Lite (and a consent declined from the store tab left the
        // Settings switch on). No-op for every other extension, and for the plan's
        // own toggles.
        if enabled {
            disabledIDs.remove(id)
            // Plan first, then load. The plan can park this row straight back off, and
            // its unload runs synchronously — before a load queued here would have
            // installed the context, so it would unload nothing and leave both
            // blockers running behind a row that reads off.
            BundledExtensions.rowDidChange(id: id)
            guard let entry = installedExtensions.first(where: { $0.id == id }), entry.isEnabled else { return }
            loadIntoEngine(entry)
        } else {
            disabledIDs.insert(id)
            stopObservingErrors(of: id)
            if #available(macOS 15.4, *) {
                loadedEngine?.unload(id: id)
            }
            BundledExtensions.rowDidChange(id: id)
        }
    }

    // MARK: - Manifest helpers

    /// What the UI shows for one extension, read straight off its manifest.
    ///
    /// A translated add-on writes `__MSG_extName__` where its name goes and keeps the
    /// real string in `_locales`. Resolving it here means the name is right everywhere
    /// downstream (rows, the consent sheet, duplicate detection) rather than in each
    /// of those places.
    nonisolated private static func parseManifest(at url: URL) -> ParsedManifest {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ParsedManifest()
        }
        let directory = url.deletingLastPathComponent()
        let defaultLocale = json["default_locale"] as? String
        let localized: (String?) -> String? = {
            ExtensionLocalization.localized($0, in: directory, defaultLocale: defaultLocale)
        }
        // `short_name` is the fallback an add-on with an unresolvable name still has;
        // past that the caller shows the folder id.
        let name = localized(json["name"] as? String) ?? localized(json["short_name"] as? String)
        // "applications" is the pre-MV3 spelling of browser_specific_settings and
        // plenty of shipped add-ons still use it.
        let settings = json["browser_specific_settings"] as? [String: Any]
            ?? json["applications"] as? [String: Any]
        let geckoID = (settings?["gecko"] as? [String: Any])?["id"] as? String
        return ParsedManifest(
            name: name,
            description: localized(json["description"] as? String),
            version: json["version"] as? String,
            geckoID: geckoID
        )
    }

    /// The same verdict the store shows, read from the installed manifest instead of AMO.
    nonisolated static func compatibility(at directory: URL) -> ExtensionCompatibility {
        ExtensionCompatibility.evaluate(permissions: requestedPermissions(at: directory))
    }

    /// Everything a manifest asks for, in one list. Content-script match patterns are in
    /// here too: they are page access the user is agreeing to just as much as
    /// `host_permissions` is, and an extension that declares only those still reads and
    /// rewrites every page it matches.
    ///
    /// Read from the pristine backup when the folder has been shim-patched: the patch
    /// adds `nativeMessaging`, which is Aura's own transport rather than anything the
    /// extension asked the user for. Consent is about what the author shipped, and
    /// hashing the patched list instead meant a patch that landed after the sheet
    /// (enable full uBO, consent, relaunch, scan patches) changed the hash and
    /// silently sent an already-approved extension back to the consent queue.
    nonisolated static func requestedPermissions(at directory: URL) -> [String] {
        let pristine = directory.appendingPathComponent(ExtensionShim.originalManifestName)
        return permissions(fromManifestAt: FileManager.default.fileExists(atPath: pristine.path)
            ? pristine
            : directory.appendingPathComponent("manifest.json"))
    }

    /// The permission set as one manifest file states it. Kept separate so the consent
    /// migration can also hash the patched manifest the old rule was written over.
    nonisolated private static func permissions(fromManifestAt url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let contentMatches = ((json["content_scripts"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["matches"] as? [String]) ?? [] }
        return ((json["permissions"] as? [String]) ?? [])
            + ((json["optional_permissions"] as? [String]) ?? [])
            + ((json["host_permissions"] as? [String]) ?? [])
            + contentMatches
    }

    /// The line the installed row shows under an extension's name: what WebKit is
    /// missing, plus the blocking-webRequest ceiling when the extension asked for it.
    nonisolated static func compatibilityNote(at directory: URL) -> String? {
        let permissions = requestedPermissions(at: directory)
        let notes = [
            ExtensionCompatibility.evaluate(permissions: permissions).detail,
            ExtensionCompatibility.webRequestNote(permissions: permissions)
        ].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private static func sanitizedID(from name: String) -> String {
        let allowed = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            + "-" + UUID().uuidString.prefix(8).lowercased()
    }
}
