import Foundation
import OSLog

/// One security-scoped folder held open. Resolving a bookmark starts access once and
/// stops the folder it replaces, instead of opening a fresh unbalanced access on every
/// lookup. `start` and `stop` are injectable so the once-only behaviour is testable.
final class SecurityScopedFolder {
    private var bookmark: Data?
    private var resolved: URL?
    private var started = false
    private let start: (URL) -> Bool
    private let stop: (URL) -> Void

    init(
        start: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.start = start
        self.stop = stop
    }

    /// The folder for `bookmark`, calling `resolve` only when the bookmark changed.
    func url(for bookmark: Data?, resolve: (Data) -> URL?) -> URL? {
        if let bookmark, bookmark == self.bookmark {
            return resolved
        }
        release()
        guard let bookmark, let url = resolve(bookmark) else { return nil }
        self.bookmark = bookmark
        resolved = url
        started = start(url)
        return url
    }

    func release() {
        if started, let resolved {
            stop(resolved)
        }
        bookmark = nil
        resolved = nil
        started = false
    }
}

/// Every user-facing preference that is not per-space, cached in memory and written
/// back through `didSet`. Nothing here reads `UserDefaults` after `init`, so a view
/// body can touch any of these without hitting the preferences store.
///
/// Domain-specific behaviour lives in extensions: `SettingsStore+Spaces` for the
/// per-container keys, `SettingsStore+Collections` for the JSON-blob mutators.
@Observable
class SettingsStore {
    static let shared = SettingsStore()

    /// Internal rather than private: the extensions in the sibling files write through it.
    @ObservationIgnored let defaults = UserDefaults.standard

    // MARK: - Global keys

    private let autoUpdateKey = "settings.autoUpdateEnabled"
    private let trackingThirdPartyKey = "settings.tracking.blockThirdParty"
    private let fingerprintingKey = "settings.tracking.blockFingerprinting"
    private let cookiesPolicyKey = "settings.cookies.policy"
    private let blockJavaScriptByDefaultKey = "privacy.javascript.blockedByDefault"
    private let extensionRequestBlockingKey = "privacy.extensionRequestBlocking"
    /// Static and internal, unlike its neighbours: the extension scan runs off the main
    /// actor and reads this key straight from `UserDefaults`, so spelling it twice is
    /// what it would cost to keep it private.
    static let extensionFullAdBlockingKey = "privacy.fullAdBlocking"
    private let launcherBlurKey = "ui.launcher.blur"
    private let addressEditingBlurKey = "ui.addressEditing.blur"
    private let sitePermissionsKey = "settings.permissions.sitePermissions"
    private let customSearchEnginesKey = "settings.customSearchEngines"
    private let globalDefaultSearchEngineKey = "settings.globalDefaultSearchEngine"
    private let customKeyboardShortcutsKey = "settings.customKeyboardShortcuts"
    private let tabAliveTimeoutKey = "settings.tabAliveTimeout"
    private let tabRemovalTimeoutKey = "settings.tabRemovalTimeout"
    private let maxRecentTabsKey = "settings.maxRecentTabs"
    private let maxLiveTabsKey = "tabs.maxLive"
    private let autoPiPEnabledKey = "settings.autoPiPEnabled"
    private let passwordsEnabledKey = "settings.passwords.enabled"
    private let passwordManagerProviderKey = "settings.passwords.provider"
    private let passwordAutofillEnabledKey = "settings.passwords.autofillEnabled"
    private let passwordAutofillSubmitEnabledKey = "settings.passwords.autofillSubmitEnabled"
    private let passwordSavePromptsEnabledKey = "settings.passwords.savePromptsEnabled"
    private let suppressedPasswordSavePromptHostsKey = "settings.passwords.suppressedSavePromptHosts"
    private let passwordSyncViaICloudKey = "passwords.syncViaICloud"
    private let extensionConsentKey = "extensions.consent"
    private let extensionPrivateWindowGrantsKey = "extensions.privateWindowGrants"
    private let extensionUpdateLastCheckKey = "extensions.updates.lastChecked"
    private let extensionAvailableUpdatesKey = "extensions.updates.available"
    private let newTabPositionKey = "tabs.newTabPosition"
    private let unloadMediaTabsKey = "tabs.unloadMedia"
    private let hibernationPresetKey = "tabs.hibernationPreset"
    private let unloadTabsOnResignKey = "tabs.unloadOnResign"
    private let foldersCollapsedByDefaultKey = "tabs.foldersCollapsedByDefault"
    private let downloadFolderBookmarkKey = "downloads.folderBookmark"
    private let askWhereToSaveDownloadsKey = "downloads.askWhereToSave"
    private let openSafeDownloadsKey = "downloads.openSafeFiles"
    private let homePageURLKey = "browser.homePage"
    private let externalLinkTargetKey = "browser.externalLinkTarget"
    private let restoreTabsOnLaunchKey = "browser.restoreTabsOnLaunch"
    private let confirmBeforeQuitKey = "browser.confirmBeforeQuit"
    private let alwaysShowScrollBarsKey = "a11y.alwaysShowScrollBars"
    private let spellCheckEnabledKey = "languages.spellCheck"
    private let showBookmarksBarKey = "ui.bookmarksBar.visible"
    private let siteZoomLevelsKey = "settings.zoom.siteLevels"
    private let firstRunCardDismissedKey = "browser.firstRunCard.dismissed"

    /// Read straight from `UserDefaults` off the main actor by `AnimationSettings`
    /// and `BrowserPage`, so both keys are public.
    static let reduceMotionKey = "a11y.reduceMotion"
    static let minimumFontSizeKey = "a11y.minimumFontSize"
    /// WebKit's own UI-process default for spell checking inside web content. Undocumented
    /// but stable since Safari 5; there is no public WKWebView API for it.
    /// ponytail: swap for the public API if WebKit ever ships one.
    static let webKitSpellCheckKey = "WebContinuousSpellCheckingEnabled"
    /// AppKit reads this per-app before the global domain, so writing it here keeps
    /// scroll bars visible in Aura without touching the system-wide setting.
    static let appleShowScrollBarsKey = "AppleShowScrollBars"

    // MARK: - Privacy and updates

    var autoUpdateEnabled: Bool {
        didSet { defaults.set(autoUpdateEnabled, forKey: autoUpdateKey) }
    }

    var blockThirdPartyTrackers: Bool {
        didSet { defaults.set(blockThirdPartyTrackers, forKey: trackingThirdPartyKey) }
    }

    var blockFingerprinting: Bool {
        didSet { defaults.set(blockFingerprinting, forKey: fingerprintingKey) }
    }

    var cookiesPolicy: CookiesPolicy {
        didSet { defaults.set(cookiesPolicy.rawValue, forKey: cookiesPolicyKey) }
    }

    /// Global default for page JavaScript. Per-site rules in `SiteJavaScriptRule` override it.
    var blockJavaScriptByDefault: Bool {
        didSet { defaults.set(blockJavaScriptByDefault, forKey: blockJavaScriptByDefaultKey) }
    }

    var sitePermissions: [String: SitePermissionSettings] {
        didSet { saveCodable(sitePermissions, forKey: sitePermissionsKey) }
    }

    // MARK: - Search

    /// The floating launcher sits mid-window and slides up when suggestions appear.
    /// Loads the injected web bundle that gives extensions a blocking `webRequest`.
    /// Off by default: WebKit runs bundle-hosting pages in its Development WebContent
    /// service, which cannot take RunningBoard foreground assertions, and the page's
    /// layers get purged a second after they paint. Takes effect on the next launch.
    var extensionRequestBlocking: Bool {
        didSet { defaults.set(extensionRequestBlocking, forKey: extensionRequestBlockingKey) }
    }

    /// Set for this session only when `AuraWebBundle.probe` finds the injected
    /// bundle silent, which is what a half-changed OS build looks like. Never
    /// persisted: the setting above stays the user's answer, this one is the
    /// running system's.
    var requestBlockingUnavailable = false

    /// Which of the two ways the probe failed, in the words the settings row shows.
    /// Session-only for the same reason as the flag above.
    var requestBlockingUnavailableReason: String?

    /// Full uBlock Origin instead of the Lite build. Off by default, and not
    /// pre-consented: full uBO blocks through `webRequest`, which only answers with
    /// the injected bundle loaded, and that moves every page onto WebKit's Development
    /// WebContent service. `BundledExtensions.plan(for:)` decides what this means for a
    /// given launch. Takes effect on the next launch, like the setting above.
    var extensionFullAdBlocking: Bool {
        didSet { defaults.set(extensionFullAdBlocking, forKey: Self.extensionFullAdBlockingKey) }
    }

    /// Blur the window behind the Cmd+T launcher.
    var launcherBlur: Bool {
        didSet { defaults.set(launcherBlur, forKey: launcherBlurKey) }
    }

    /// Blur the window while the address field is being edited.
    var addressEditingBlur: Bool {
        didSet { defaults.set(addressEditingBlur, forKey: addressEditingBlurKey) }
    }

    var customSearchEngines: [CustomSearchEngine] {
        didSet { saveCodable(customSearchEngines, forKey: customSearchEnginesKey) }
    }

    var globalDefaultSearchEngine: String? {
        didSet { defaults.set(globalDefaultSearchEngine, forKey: globalDefaultSearchEngineKey) }
    }

    var customKeyboardShortcuts: [String: KeyChord] {
        didSet { saveCodable(customKeyboardShortcuts, forKey: customKeyboardShortcutsKey) }
    }

    // MARK: - Tab lifetime

    var tabAliveTimeout: TimeInterval {
        didSet { defaults.set(tabAliveTimeout, forKey: tabAliveTimeoutKey) }
    }

    var tabRemovalTimeout: TimeInterval {
        didSet { defaults.set(tabRemovalTimeout, forKey: tabRemovalTimeoutKey) }
    }

    var maxRecentTabs: Int {
        didSet { defaults.set(maxRecentTabs, forKey: maxRecentTabsKey) }
    }

    /// Ceiling on live `WKWebView`s, independent of `tabAliveTimeout`. A tab can be
    /// well inside the timeout and still be evicted when 40 others are ahead of it.
    /// 0 turns the cap off and leaves eviction to the timeout alone.
    var maxLiveTabs: Int {
        didSet { defaults.set(maxLiveTabs, forKey: maxLiveTabsKey) }
    }

    var autoPiPEnabled: Bool {
        didSet { defaults.set(autoPiPEnabled, forKey: autoPiPEnabledKey) }
    }

    // MARK: - Passwords

    var passwordsEnabled: Bool {
        didSet { defaults.set(passwordsEnabled, forKey: passwordsEnabledKey) }
    }

    var passwordManagerProvider: PasswordManagerProviderKind {
        didSet { defaults.set(passwordManagerProvider.rawValue, forKey: passwordManagerProviderKey) }
    }

    var passwordAutofillEnabled: Bool {
        didSet { defaults.set(passwordAutofillEnabled, forKey: passwordAutofillEnabledKey) }
    }

    var passwordAutofillSubmitEnabled: Bool {
        didSet { defaults.set(passwordAutofillSubmitEnabled, forKey: passwordAutofillSubmitEnabledKey) }
    }

    var passwordSavePromptsEnabled: Bool {
        didSet { defaults.set(passwordSavePromptsEnabled, forKey: passwordSavePromptsEnabledKey) }
    }

    /// Whether a newly saved credential is marked `kSecAttrSynchronizable`. Off unless
    /// the user asks: syncing puts the password, its host and its username on every
    /// device signed into the Apple ID, including ones that have never run Aura.
    var passwordSyncViaICloud: Bool {
        didSet { defaults.set(passwordSyncViaICloud, forKey: passwordSyncViaICloudKey) }
    }

    private(set) var suppressedPasswordSavePromptHosts: Set<String> {
        didSet { defaults.set(
            Array(suppressedPasswordSavePromptHosts).sorted(),
            forKey: suppressedPasswordSavePromptHostsKey
        ) }
    }

    // MARK: - Extensions

    /// What the user agreed to when each extension was installed, keyed by the folder id
    /// the extension lives under. An entry missing means nobody has seen this extension's
    /// permissions yet, which is what makes `ExtensionConsent` ask.
    var extensionConsent: [String: ExtensionConsentRecord] {
        didSet { saveCodable(extensionConsent, forKey: extensionConsentKey) }
    }

    /// Extensions the user let run in private windows, by folder id. Off for everything
    /// that is not in here, which is Firefox's rule: an extension is installed for normal
    /// browsing and has to be allowed into private browsing separately.
    var extensionPrivateWindowGrants: Set<String> {
        didSet {
            defaults.set(Array(extensionPrivateWindowGrants).sorted(), forKey: extensionPrivateWindowGrantsKey)
        }
    }

    /// When the AMO version check last ran. Nil until the first check; the check itself
    /// runs at most once a day off this.
    var extensionUpdateLastCheck: Date? {
        didSet { defaults.set(extensionUpdateLastCheck, forKey: extensionUpdateLastCheckKey) }
    }

    /// The newest version AMO reported per extension id, from the last check. Kept so the
    /// "Update available" row survives a relaunch without asking AMO again.
    var extensionAvailableUpdates: [String: String] {
        didSet { saveCodable(extensionAvailableUpdates, forKey: extensionAvailableUpdatesKey) }
    }

    // MARK: - Tab management

    var newTabPosition: NewTabPosition {
        didSet { defaults.set(newTabPosition.rawValue, forKey: newTabPositionKey) }
    }

    /// Off by default: hibernating a tab stops whatever it is playing.
    var unloadMediaTabs: Bool {
        didSet { defaults.set(unloadMediaTabs, forKey: unloadMediaTabsKey) }
    }

    /// How much the memory-pressure pass unloads at once. Separate from the age and
    /// count policies, which run on their own timer regardless of pressure.
    var hibernationPreset: TabHibernationPreset {
        didSet { defaults.set(hibernationPreset.rawValue, forKey: hibernationPresetKey) }
    }

    /// Off by default: giving memory back when Aura loses focus costs a reload on every
    /// tab when it comes back.
    var unloadTabsOnResign: Bool {
        didSet { defaults.set(unloadTabsOnResign, forKey: unloadTabsOnResignKey) }
    }

    var foldersCollapsedByDefault: Bool {
        didSet { defaults.set(foldersCollapsedByDefault, forKey: foldersCollapsedByDefaultKey) }
    }

    // MARK: - Downloads

    /// Security-scoped bookmark for the folder the user picked. Nil means the system
    /// Downloads folder, which the sandbox grants outright.
    private(set) var downloadFolderBookmark: Data? {
        didSet { defaults.set(downloadFolderBookmark, forKey: downloadFolderBookmarkKey) }
    }

    var askWhereToSaveDownloads: Bool {
        didSet { defaults.set(askWhereToSaveDownloads, forKey: askWhereToSaveDownloadsKey) }
    }

    var openSafeDownloads: Bool {
        didSet { defaults.set(openSafeDownloads, forKey: openSafeDownloadsKey) }
    }

    // MARK: - Browsing

    /// Empty means the built-in `aura://home` page.
    var homePageURLString: String {
        didSet { defaults.set(homePageURLString, forKey: homePageURLKey) }
    }

    var externalLinkTarget: ExternalLinkTarget {
        didSet { defaults.set(externalLinkTarget.rawValue, forKey: externalLinkTargetKey) }
    }

    var restoreTabsOnLaunch: Bool {
        didSet { defaults.set(restoreTabsOnLaunch, forKey: restoreTabsOnLaunchKey) }
    }

    var confirmBeforeQuit: Bool {
        didSet { defaults.set(confirmBeforeQuit, forKey: confirmBeforeQuitKey) }
    }

    /// Whether the bookmarks bar sits under the toolbar. On by default: a bar nobody can
    /// see is a feature nobody finds, and ⇧⌘B is one keystroke away from hiding it.
    var showBookmarksBar: Bool {
        didSet { defaults.set(showBookmarksBar, forKey: showBookmarksBarKey) }
    }

    /// Set once the home page's first-run card has been dismissed, or acted on. Sticky
    /// rather than session-scoped: a card offering to change the default browser is a
    /// question, and asking it again on every new tab after the answer was no is the
    /// behaviour people uninstall a browser over.
    var firstRunCardDismissed: Bool {
        didSet { defaults.set(firstRunCardDismissed, forKey: firstRunCardDismissedKey) }
    }

    // MARK: - Accessibility and languages

    /// `AnimationSettings` reads this from view bodies dozens of times a frame, so the
    /// setter pushes the new value into its cache instead of leaving it to re-read.
    var reduceMotion: Bool {
        didSet {
            defaults.set(reduceMotion, forKey: Self.reduceMotionKey)
            AnimationSettings.reduceMotionDidChange(to: reduceMotion)
        }
    }

    /// Points. 0 leaves WebKit's own minimum in place. Applies to web views made after
    /// the change, so existing tabs pick it up on their next reload.
    var minimumFontSize: Double {
        didSet { defaults.set(minimumFontSize, forKey: Self.minimumFontSizeKey) }
    }

    var alwaysShowScrollBars: Bool {
        didSet {
            defaults.set(alwaysShowScrollBars, forKey: alwaysShowScrollBarsKey)
            defaults.set(alwaysShowScrollBars ? "Always" : "Automatic", forKey: Self.appleShowScrollBarsKey)
        }
    }

    var spellCheckEnabled: Bool {
        didSet {
            defaults.set(spellCheckEnabled, forKey: spellCheckEnabledKey)
            defaults.set(spellCheckEnabled, forKey: Self.webKitSpellCheckKey)
        }
    }

    // MARK: - Per-site zoom

    /// Page zoom the user pinned to a site, keyed by registrable domain so every
    /// subdomain of a site shares one level. 100% is never stored: a site that is back
    /// at the default leaves the map rather than sitting in it as 1.0.
    /// Mutated through `SettingsStore+Collections`.
    var siteZoomLevels: [String: Double] {
        didSet { saveCodable(siteZoomLevels, forKey: siteZoomLevelsKey) }
    }

    // MARK: - Per-space storage

    /// Bumped by every per-space setter so the getters in `SettingsStore+Spaces` have
    /// something observable to read. Internal because those live in another file.
    var containerSettingsRevision = 0

    /// Decoded per-space privacy blobs, owned by `SettingsStore+Spaces`.
    @ObservationIgnored var privacySettingsCache: [UUID: SpacePrivacySettings] = [:]

    init() {
        autoUpdateEnabled = defaults.object(forKey: autoUpdateKey) as? Bool ?? true
        blockThirdPartyTrackers = defaults.bool(forKey: trackingThirdPartyKey)
        blockFingerprinting = defaults.object(forKey: fingerprintingKey) as? Bool ?? true
        cookiesPolicy = defaults.string(forKey: cookiesPolicyKey)
            .flatMap(CookiesPolicy.init(rawValue:)) ?? .allowAll
        blockJavaScriptByDefault = defaults.bool(forKey: blockJavaScriptByDefaultKey)
        // Full uBlock Origin is the default blocker; a profile that never touched the
        // switches gets it, one that switched them off stays off.
        extensionRequestBlocking = defaults.object(forKey: extensionRequestBlockingKey) as? Bool ?? true
        extensionFullAdBlocking = defaults.object(forKey: Self.extensionFullAdBlockingKey) as? Bool ?? true
        launcherBlur = defaults.object(forKey: launcherBlurKey) as? Bool ?? true
        addressEditingBlur = defaults.object(forKey: addressEditingBlurKey) as? Bool ?? true
        sitePermissions = Self.loadCodable([String: SitePermissionSettings].self, key: sitePermissionsKey) ?? [:]
        customSearchEngines = Self.loadCodable([CustomSearchEngine].self, key: customSearchEnginesKey) ?? []
        globalDefaultSearchEngine = defaults.string(forKey: globalDefaultSearchEngineKey)
        customKeyboardShortcuts = Self.loadCodable([String: KeyChord].self, key: customKeyboardShortcutsKey) ?? [:]

        let timeouts = Self.normalizedTimeouts(
            defaults: defaults,
            aliveKey: tabAliveTimeoutKey,
            removalKey: tabRemovalTimeoutKey
        )
        tabAliveTimeout = timeouts.alive
        tabRemovalTimeout = timeouts.removal

        // `integer(forKey:)` cannot tell "never set" from a stored 0, so a user who
        // picked 0 recent tabs used to get 5 back on the next launch.
        maxRecentTabs = defaults.object(forKey: maxRecentTabsKey) as? Int ?? 5
        maxLiveTabs = defaults.object(forKey: maxLiveTabsKey) as? Int ?? 12
        autoPiPEnabled = defaults.object(forKey: autoPiPEnabledKey) as? Bool ?? true

        passwordsEnabled = defaults.object(forKey: passwordsEnabledKey) as? Bool ?? true
        passwordManagerProvider = defaults.string(forKey: passwordManagerProviderKey)
            .flatMap(PasswordManagerProviderKind.init(rawValue:)) ?? .ora
        passwordAutofillEnabled = defaults.object(forKey: passwordAutofillEnabledKey) as? Bool ?? true
        passwordAutofillSubmitEnabled = defaults.object(forKey: passwordAutofillSubmitEnabledKey) as? Bool ?? true
        passwordSavePromptsEnabled = defaults.object(forKey: passwordSavePromptsEnabledKey) as? Bool ?? true
        passwordSyncViaICloud = defaults.bool(forKey: passwordSyncViaICloudKey)
        extensionConsent = Self.loadCodable([String: ExtensionConsentRecord].self, key: extensionConsentKey) ?? [:]
        extensionPrivateWindowGrants = Set(defaults.stringArray(forKey: extensionPrivateWindowGrantsKey) ?? [])
        extensionUpdateLastCheck = defaults.object(forKey: extensionUpdateLastCheckKey) as? Date
        extensionAvailableUpdates = Self.loadCodable([String: String].self, key: extensionAvailableUpdatesKey) ?? [:]
        suppressedPasswordSavePromptHosts = Set(
            defaults.stringArray(forKey: suppressedPasswordSavePromptHostsKey) ?? []
        )

        newTabPosition = defaults.string(forKey: newTabPositionKey)
            .flatMap(NewTabPosition.init(rawValue:)) ?? .top
        unloadMediaTabs = defaults.bool(forKey: unloadMediaTabsKey)
        hibernationPreset = defaults.string(forKey: hibernationPresetKey)
            .flatMap(TabHibernationPreset.init(rawValue:)) ?? .balanced
        unloadTabsOnResign = defaults.bool(forKey: unloadTabsOnResignKey)
        foldersCollapsedByDefault = defaults.bool(forKey: foldersCollapsedByDefaultKey)

        downloadFolderBookmark = defaults.data(forKey: downloadFolderBookmarkKey)
        askWhereToSaveDownloads = defaults.bool(forKey: askWhereToSaveDownloadsKey)
        openSafeDownloads = defaults.bool(forKey: openSafeDownloadsKey)

        homePageURLString = defaults.string(forKey: homePageURLKey) ?? ""
        externalLinkTarget = defaults.string(forKey: externalLinkTargetKey)
            .flatMap(ExternalLinkTarget.init(rawValue:)) ?? .currentSpace
        restoreTabsOnLaunch = defaults.object(forKey: restoreTabsOnLaunchKey) as? Bool ?? true
        confirmBeforeQuit = defaults.object(forKey: confirmBeforeQuitKey) as? Bool ?? true
        showBookmarksBar = defaults.object(forKey: showBookmarksBarKey) as? Bool ?? true
        firstRunCardDismissed = defaults.bool(forKey: firstRunCardDismissedKey)

        reduceMotion = defaults.bool(forKey: Self.reduceMotionKey)
        minimumFontSize = defaults.double(forKey: Self.minimumFontSizeKey)
        alwaysShowScrollBars = defaults.bool(forKey: alwaysShowScrollBarsKey)
        spellCheckEnabled = defaults.object(forKey: spellCheckEnabledKey) as? Bool ?? true
        siteZoomLevels = Self.loadCodable([String: Double].self, key: siteZoomLevelsKey) ?? [:]
        defaults.set(spellCheckEnabled, forKey: Self.webKitSpellCheckKey)
    }

    // MARK: - Browsing helpers

    /// The Home button's target. A bare host gets `https://`, and anything that does not
    /// parse falls back to the built-in page rather than navigating nowhere.
    var homePageURL: URL {
        let trimmed = homePageURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .oraHome }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)") ?? .oraHome
    }

    /// What a space with no stored privacy blob of its own inherits.
    var legacyPrivacySettings: SpacePrivacySettings {
        SpacePrivacySettings(
            blockThirdPartyTrackers: blockThirdPartyTrackers,
            blockFingerprinting: blockFingerprinting,
            cookiesPolicy: cookiesPolicy
        )
    }

    // MARK: - Download folder

    @ObservationIgnored private let downloadFolderAccess = SecurityScopedFolder()

    /// The folder downloads are written to, or nil when the system Downloads folder
    /// (granted outright by the sandbox) should be used. Called per download and from the
    /// save panel, so the security-scoped access is started once per bookmark rather than
    /// once per call and never stopped.
    func resolvedDownloadFolder() -> URL? {
        guard downloadFolderBookmark != nil else {
            downloadFolderAccess.release()
            return nil
        }
        return downloadFolderAccess.url(for: downloadFolderBookmark) { bookmark in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                downloadFolderBookmark = nil
                return nil
            }
            if isStale {
                storeDownloadFolderBookmark(for: url)
            }
            return url
        }
    }

    func setDownloadFolder(_ url: URL?) {
        guard let url else {
            downloadFolderAccess.release()
            downloadFolderBookmark = nil
            return
        }
        storeDownloadFolderBookmark(for: url)
    }

    private func storeDownloadFolderBookmark(for url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        downloadFolderBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    // MARK: - Password prompts

    /// Writes to a `private(set)` property, so it stays in this file.
    func suppressPasswordSavePrompts(for host: String) {
        let normalizedHost = PasswordManagerService.normalizeHost(host)
        guard !normalizedHost.isEmpty else { return }
        suppressedPasswordSavePromptHosts.insert(normalizedHost)
    }

    // MARK: - Codable helpers

    /// Internal rather than private: the extensions in the sibling files use both.
    func saveCodable(_ value: some Encodable, forKey key: String) {
        do {
            try defaults.set(JSONEncoder().encode(value), forKey: key)
        } catch {
            Self.log.error(
                "Failed to encode \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// `previous` is what the caller already holds in memory. A blob that will not decode
    /// used to silently reset the setting to empty; keeping the live value means a
    /// corrupt write cannot wipe the user's search engines or shortcuts.
    static func loadCodable<T: Decodable>(_ type: T.Type, key: String, previous: T? = nil) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return previous }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.error(
                "Failed to decode \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return previous
        }
    }

    static let log = AuraLog.category("Settings")

    // MARK: - Normalization helpers

    /// The two hibernation timeouts are stored as raw seconds but the UI only offers a
    /// fixed set, so a value from an older build (or a hand-edited plist) is snapped to
    /// the nearest offered one and written straight back.
    private static func normalizedTimeouts(
        defaults: UserDefaults,
        aliveKey: String,
        removalKey: String
    ) -> (alive: TimeInterval, removal: TimeInterval) {
        let supported: [TimeInterval] = [
            60 * 60,           // 1 hour
            6 * 60 * 60,       // 6 hours
            12 * 60 * 60,      // 12 hours
            24 * 60 * 60,      // 1 day
            2 * 24 * 60 * 60,  // 2 days
            365 * 24 * 60 * 60 // "Never" sentinel
        ]
        let alive = normalizeTimeout(
            defaults.double(forKey: aliveKey), defaultSeconds: 60 * 60, supported: supported
        )
        let removal = normalizeTimeout(
            defaults.double(forKey: removalKey), defaultSeconds: 24 * 60 * 60, supported: supported
        )
        defaults.set(alive, forKey: aliveKey)
        defaults.set(removal, forKey: removalKey)
        return (alive, removal)
    }

    private static func normalizeTimeout(
        _ raw: TimeInterval,
        defaultSeconds: TimeInterval,
        supported: [TimeInterval]
    ) -> TimeInterval {
        let value: TimeInterval = raw == 0 ? defaultSeconds : raw
        if supported.contains(value) {
            return value
        }
        return supported.min { abs($0 - value) < abs($1 - value) } ?? defaultSeconds
    }
}
