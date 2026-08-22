import Foundation

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
    private let launcherRisesForSuggestionsKey = "launcher.risesForSuggestions"
    private let extensionRequestBlockingKey = "privacy.extensionRequestBlocking"
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
    private let newTabPositionKey = "tabs.newTabPosition"
    private let unloadMediaTabsKey = "tabs.unloadMedia"
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
    var launcherRisesForSuggestions: Bool {
        didSet { defaults.set(launcherRisesForSuggestions, forKey: launcherRisesForSuggestionsKey) }
    }

    /// Loads the injected web bundle that gives extensions a blocking `webRequest`.
    /// Off by default: WebKit runs bundle-hosting pages in its Development WebContent
    /// service, which cannot take RunningBoard foreground assertions, and the page's
    /// layers get purged a second after they paint. Takes effect on the next launch.
    var extensionRequestBlocking: Bool {
        didSet { defaults.set(extensionRequestBlocking, forKey: extensionRequestBlockingKey) }
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

    private(set) var suppressedPasswordSavePromptHosts: Set<String> {
        didSet { defaults.set(
            Array(suppressedPasswordSavePromptHosts).sorted(),
            forKey: suppressedPasswordSavePromptHostsKey
        ) }
    }

    // MARK: - Tab management

    var newTabPosition: NewTabPosition {
        didSet { defaults.set(newTabPosition.rawValue, forKey: newTabPositionKey) }
    }

    /// Off by default: hibernating a tab stops whatever it is playing.
    var unloadMediaTabs: Bool {
        didSet { defaults.set(unloadMediaTabs, forKey: unloadMediaTabsKey) }
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
        launcherRisesForSuggestions = defaults.object(forKey: launcherRisesForSuggestionsKey) as? Bool ?? true
        extensionRequestBlocking = defaults.bool(forKey: extensionRequestBlockingKey)
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

        let maxRecentTabsValue = defaults.integer(forKey: maxRecentTabsKey)
        maxRecentTabs = maxRecentTabsValue == 0 ? 5 : maxRecentTabsValue
        maxLiveTabs = defaults.object(forKey: maxLiveTabsKey) as? Int ?? 12
        autoPiPEnabled = defaults.object(forKey: autoPiPEnabledKey) as? Bool ?? true

        passwordsEnabled = defaults.object(forKey: passwordsEnabledKey) as? Bool ?? true
        passwordManagerProvider = defaults.string(forKey: passwordManagerProviderKey)
            .flatMap(PasswordManagerProviderKind.init(rawValue:)) ?? .ora
        passwordAutofillEnabled = defaults.object(forKey: passwordAutofillEnabledKey) as? Bool ?? true
        passwordAutofillSubmitEnabled = defaults.object(forKey: passwordAutofillSubmitEnabledKey) as? Bool ?? true
        passwordSavePromptsEnabled = defaults.object(forKey: passwordSavePromptsEnabledKey) as? Bool ?? true
        suppressedPasswordSavePromptHosts = Set(
            defaults.stringArray(forKey: suppressedPasswordSavePromptHostsKey) ?? []
        )

        newTabPosition = defaults.string(forKey: newTabPositionKey)
            .flatMap(NewTabPosition.init(rawValue:)) ?? .top
        unloadMediaTabs = defaults.bool(forKey: unloadMediaTabsKey)
        foldersCollapsedByDefault = defaults.bool(forKey: foldersCollapsedByDefaultKey)

        downloadFolderBookmark = defaults.data(forKey: downloadFolderBookmarkKey)
        askWhereToSaveDownloads = defaults.bool(forKey: askWhereToSaveDownloadsKey)
        openSafeDownloads = defaults.bool(forKey: openSafeDownloadsKey)

        homePageURLString = defaults.string(forKey: homePageURLKey) ?? ""
        externalLinkTarget = defaults.string(forKey: externalLinkTargetKey)
            .flatMap(ExternalLinkTarget.init(rawValue:)) ?? .currentSpace
        restoreTabsOnLaunch = defaults.object(forKey: restoreTabsOnLaunchKey) as? Bool ?? true
        confirmBeforeQuit = defaults.object(forKey: confirmBeforeQuitKey) as? Bool ?? true

        reduceMotion = defaults.bool(forKey: Self.reduceMotionKey)
        minimumFontSize = defaults.double(forKey: Self.minimumFontSizeKey)
        alwaysShowScrollBars = defaults.bool(forKey: alwaysShowScrollBarsKey)
        spellCheckEnabled = defaults.object(forKey: spellCheckEnabledKey) as? Bool ?? true
        defaults.set(spellCheckEnabled, forKey: Self.webKitSpellCheckKey)
    }

    // MARK: - Browsing helpers

    /// The Home button's target. A bare host gets `https://`, and anything that does not
    /// parse falls back to the built-in page rather than navigating nowhere.
    var homePageURL: URL {
        let trimmed = homePageURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .oraHome }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
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

    /// The folder downloads are written to, or nil when the system Downloads folder
    /// (granted outright by the sandbox) should be used.
    ///
    /// ponytail: access is started once and never stopped, which is fine for a folder
    /// used for the app's whole lifetime. Balance it if the picker ever moves per-window.
    func resolvedDownloadFolder() -> URL? {
        guard let bookmark = downloadFolderBookmark else { return nil }
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
        _ = url.startAccessingSecurityScopedResource()
        if isStale { storeDownloadFolderBookmark(for: url) }
        return url
    }

    func setDownloadFolder(_ url: URL?) {
        guard let url else {
            downloadFolderBookmark = nil
            return
        }
        storeDownloadFolderBookmark(for: url)
    }

    private func storeDownloadFolderBookmark(for url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
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
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    static func loadCodable<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

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
        if supported.contains(value) { return value }
        return supported.min { abs($0 - value) < abs($1 - value) } ?? defaultSeconds
    }
}
