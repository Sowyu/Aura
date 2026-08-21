import AppKit
import Foundation
import SwiftUI

struct SitePermissionSettings: Codable, Hashable, Identifiable {
    var id: String {
        host
    }

    let host: String
    var camera: Bool
    var microphone: Bool
    var location: Bool
    var notifications: Bool
}

enum AutoClearTabsAfter: String, CaseIterable, Identifiable, Codable {
    case never = "Never"
    case oneHour = "1 Hour"
    case oneDay = "1 Day"
    case oneWeek = "1 Week"
    var id: String {
        rawValue
    }

    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .oneHour: return 3600
        case .oneDay: return 86400
        case .oneWeek: return 604_800
        }
    }
}

/// Where a freshly opened tab lands in the sidebar list.
enum NewTabPosition: String, CaseIterable, Identifiable, Codable {
    case top
    case bottom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Top of the list"
        case .bottom: return "Bottom of the list"
        }
    }
}

/// What happens to a link handed to Aura by another app.
enum ExternalLinkTarget: String, CaseIterable, Identifiable, Codable {
    case currentSpace
    case newWindow
    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentSpace: return "The current space"
        case .newWindow: return "A new window"
        }
    }
}

struct CustomSearchEngine: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let searchURL: String
    let aliases: [String]
    let faviconData: Data?
    let faviconBackgroundColorData: Data?
    let isAIChat: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        searchURL: String,
        aliases: [String] = [],
        faviconData: Data? = nil,
        faviconBackgroundColorData: Data? = nil,
        isAIChat: Bool = false
    ) {
        self.id = id
        self.name = name
        self.searchURL = searchURL
        self.aliases = aliases
        self.faviconData = faviconData
        self.faviconBackgroundColorData = faviconBackgroundColorData
        self.isAIChat = isAIChat
    }

    var favicon: NSImage? {
        guard let data = faviconData else { return nil }
        return NSImage(data: data)
    }

    var faviconBackgroundColor: Color? {
        guard let data = faviconBackgroundColorData else { return nil }
        do {
            let nsColor = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
            return nsColor.map(Color.init)
        } catch {
            return nil
        }
    }

    static func createWithFavicon(
        id: String = UUID().uuidString,
        name: String,
        searchURL: String,
        aliases: [String] = [],
        isAIChat: Bool = false,
        completion: @escaping (CustomSearchEngine) -> Void
    ) {
        let faviconService = FaviconService.shared

        // Try to fetch favicon synchronously first (from cache)
        if let favicon = faviconService.getFavicon(for: searchURL) {
            let faviconData = favicon.tiffRepresentation
            let backgroundColor = Color(favicon.averageColor())
            let colorData = try? NSKeyedArchiver.archivedData(
                withRootObject: NSColor(backgroundColor),
                requiringSecureCoding: false
            )

            let engine = CustomSearchEngine(
                id: id,
                name: name,
                searchURL: searchURL,
                aliases: aliases,
                faviconData: faviconData,
                faviconBackgroundColorData: colorData,
                isAIChat: isAIChat
            )
            completion(engine)
        } else {
            // Fetch async and update
            faviconService.fetchFaviconSync(for: searchURL) { favicon in
                DispatchQueue.main.async {
                    var faviconData: Data?
                    var colorData: Data?

                    if let favicon {
                        faviconData = favicon.tiffRepresentation
                        let backgroundColor = Color(favicon.averageColor())
                        colorData = try? NSKeyedArchiver.archivedData(
                            withRootObject: NSColor(backgroundColor),
                            requiringSecureCoding: false
                        )
                    }

                    let engine = CustomSearchEngine(
                        id: id,
                        name: name,
                        searchURL: searchURL,
                        aliases: aliases,
                        faviconData: faviconData,
                        faviconBackgroundColorData: colorData,
                        isAIChat: isAIChat
                    )
                    completion(engine)
                }
            }
        }
    }
}

@Observable
class SettingsStore {
    static let shared = SettingsStore()
    @ObservationIgnored private let defaults = UserDefaults.standard

    // MARK: - Global keys

    private let autoUpdateKey = "settings.autoUpdateEnabled"
    private let trackingThirdPartyKey = "settings.tracking.blockThirdParty"
    private let fingerprintingKey = "settings.tracking.blockFingerprinting"
    private let adBlockingKey = "settings.tracking.adBlocking"
    private let cookiesPolicyKey = "settings.cookies.policy"
    private let blockJavaScriptByDefaultKey = "privacy.javascript.blockedByDefault"
    private let launcherRisesForSuggestionsKey = "launcher.risesForSuggestions"
    private let advancedBlockingEnabledKey = "privacy.advancedBlocking.enabled"
    private let adBlockFilterListsKey = "settings.adBlock.filterLists"
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

    // MARK: - Per-Container

    private func keyForDefaultSearch(for containerId: UUID) -> String {
        "settings.container.\(containerId.uuidString).defaultSearch"
    }

    private func keyForDefaultAI(for containerId: UUID) -> String {
        "settings.container.\(containerId.uuidString).defaultAI"
    }

    private func keyForAutoClear(for containerId: UUID) -> String {
        "settings.container.\(containerId.uuidString).autoClearTabsAfter"
    }

    private func keyForPrivacySettings(for containerId: UUID) -> String {
        "settings.container.\(containerId.uuidString).privacy"
    }

    var autoUpdateEnabled: Bool {
        didSet { defaults.set(autoUpdateEnabled, forKey: autoUpdateKey) }
    }

    var blockThirdPartyTrackers: Bool {
        didSet { defaults.set(blockThirdPartyTrackers, forKey: trackingThirdPartyKey) }
    }

    var blockFingerprinting: Bool {
        didSet { defaults.set(blockFingerprinting, forKey: fingerprintingKey) }
    }

    var adBlocking: Bool {
        didSet { defaults.set(adBlocking, forKey: adBlockingKey) }
    }

    var cookiesPolicy: CookiesPolicy {
        didSet { defaults.set(cookiesPolicy.rawValue, forKey: cookiesPolicyKey) }
    }

    /// The floating launcher sits mid-window and slides up when suggestions appear.
    var launcherRisesForSuggestions: Bool {
        didSet { defaults.set(launcherRisesForSuggestions, forKey: launcherRisesForSuggestionsKey) }
    }

    /// Global default for page JavaScript. Per-site rules in `SiteJavaScriptRule` override it.
    var blockJavaScriptByDefault: Bool {
        didSet { defaults.set(blockJavaScriptByDefault, forKey: blockJavaScriptByDefaultKey) }
    }

    /// Applies the filter rules WebKit's content blocking format cannot express
    /// (scriptlets, procedural selectors, CSS injection). Per-site overrides live in
    /// `AdvancedBlockingService`.
    var advancedBlockingEnabled: Bool {
        didSet {
            defaults.set(advancedBlockingEnabled, forKey: advancedBlockingEnabledKey)
            NotificationCenter.default.post(name: AdvancedBlockingService.didChangeNotification, object: nil)
        }
    }

    var sitePermissions: [String: SitePermissionSettings] {
        didSet { saveCodable(sitePermissions, forKey: sitePermissionsKey) }
    }

    private(set) var adBlockFilterLists: [FilterListRecord] {
        didSet { saveCodable(adBlockFilterLists, forKey: adBlockFilterListsKey) }
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

    var reduceMotion: Bool {
        didSet { defaults.set(reduceMotion, forKey: Self.reduceMotionKey) }
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

    init() {
        autoUpdateEnabled = defaults.object(forKey: autoUpdateKey) as? Bool ?? true
        blockThirdPartyTrackers = defaults.bool(forKey: trackingThirdPartyKey)
        blockFingerprinting = defaults.object(forKey: fingerprintingKey) as? Bool ?? true
        adBlocking = defaults.bool(forKey: adBlockingKey)
        if let raw = defaults.string(forKey: cookiesPolicyKey),
           let policy = CookiesPolicy(rawValue: raw)
        {
            cookiesPolicy = policy
        } else {
            cookiesPolicy = .allowAll
        }

        blockJavaScriptByDefault = defaults.bool(forKey: blockJavaScriptByDefaultKey)
        launcherRisesForSuggestions = defaults.object(forKey: launcherRisesForSuggestionsKey) as? Bool ?? true
        advancedBlockingEnabled = defaults.object(forKey: advancedBlockingEnabledKey) as? Bool ?? true

        sitePermissions =
            Self.loadCodable([String: SitePermissionSettings].self, key: sitePermissionsKey) ?? [:]

        adBlockFilterLists = FilterListCatalogService.shared.normalizedRecords(
            from: Self.loadCodable([FilterListRecord].self, key: adBlockFilterListsKey) ?? []
        )

        customSearchEngines =
            Self.loadCodable([CustomSearchEngine].self, key: customSearchEnginesKey) ?? []

        globalDefaultSearchEngine = defaults.string(forKey: globalDefaultSearchEngineKey)

        customKeyboardShortcuts =
            Self.loadCodable([String: KeyChord].self, key: customKeyboardShortcutsKey) ?? [:]

        let aliveTimeoutValue = defaults.double(forKey: tabAliveTimeoutKey)
        let supportedTimeouts: [TimeInterval] = [
            60 * 60,           // 1 hour
            6 * 60 * 60,       // 6 hours
            12 * 60 * 60,      // 12 hours
            24 * 60 * 60,      // 1 day
            2 * 24 * 60 * 60,  // 2 days
            365 * 24 * 60 * 60 // "Never" sentinel
        ]
        let normalizedAlive = Self.normalizeTimeout(
            aliveTimeoutValue,
            defaultSeconds: 60 * 60,
            supported: supportedTimeouts
        )
        defaults.set(normalizedAlive, forKey: tabAliveTimeoutKey)
        tabAliveTimeout = normalizedAlive

        let removalTimeoutValue = defaults.double(forKey: tabRemovalTimeoutKey)
        let normalizedRemoval = Self.normalizeTimeout(
            removalTimeoutValue,
            defaultSeconds: 24 * 60 * 60,
            supported: supportedTimeouts
        )
        defaults.set(normalizedRemoval, forKey: tabRemovalTimeoutKey)
        tabRemovalTimeout = normalizedRemoval

        let maxRecentTabsValue = defaults.integer(forKey: maxRecentTabsKey)
        maxRecentTabs = maxRecentTabsValue == 0 ? 5 : maxRecentTabsValue
        maxLiveTabs = defaults.object(forKey: maxLiveTabsKey) as? Int ?? 12

        autoPiPEnabled = defaults.object(forKey: autoPiPEnabledKey) as? Bool ?? true
        passwordsEnabled = defaults.object(forKey: passwordsEnabledKey) as? Bool ?? true
        if let raw = defaults.string(forKey: passwordManagerProviderKey),
           let provider = PasswordManagerProviderKind(rawValue: raw)
        {
            passwordManagerProvider = provider
        } else {
            passwordManagerProvider = .ora
        }
        passwordAutofillEnabled = defaults.object(forKey: passwordAutofillEnabledKey) as? Bool ?? true
        passwordAutofillSubmitEnabled = defaults.object(forKey: passwordAutofillSubmitEnabledKey) as? Bool ?? true
        passwordSavePromptsEnabled = defaults.object(forKey: passwordSavePromptsEnabledKey) as? Bool ?? true
        suppressedPasswordSavePromptHosts = Set(defaults
            .stringArray(forKey: suppressedPasswordSavePromptHostsKey) ?? [])

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

    // MARK: - Per-container helpers

    /// Per-container settings live only in `UserDefaults`, so no stored property
    /// changes when one is written. Observation has no `objectWillChange`, so the
    /// getters read this counter and the setters bump it: same invalidation, same
    /// granularity as the hand-rolled sends it replaces.
    private var containerSettingsRevision = 0

    func defaultSearchEngineId(for containerId: UUID) -> String? {
        _ = containerSettingsRevision
        return defaults.string(forKey: keyForDefaultSearch(for: containerId))
    }

    func setDefaultSearchEngineId(_ id: String?, for containerId: UUID) {
        defaults.set(id, forKey: keyForDefaultSearch(for: containerId))
        containerSettingsRevision &+= 1
    }

    func defaultAIEngineId(for containerId: UUID) -> String? {
        _ = containerSettingsRevision
        return defaults.string(forKey: keyForDefaultAI(for: containerId))
    }

    func setDefaultAIEngineId(_ id: String?, for containerId: UUID) {
        defaults.set(id, forKey: keyForDefaultAI(for: containerId))
        containerSettingsRevision &+= 1
    }

    func autoClearTabsAfter(for containerId: UUID) -> AutoClearTabsAfter {
        _ = containerSettingsRevision
        if let raw = defaults.string(forKey: keyForAutoClear(for: containerId)),
           let value = AutoClearTabsAfter(rawValue: raw)
        {
            return value
        }
        return .never
    }

    func setAutoClearTabsAfter(_ value: AutoClearTabsAfter, for containerId: UUID) {
        defaults.set(value.rawValue, forKey: keyForAutoClear(for: containerId))
        containerSettingsRevision &+= 1
    }

    func privacySettings(for containerId: UUID) -> SpacePrivacySettings {
        _ = containerSettingsRevision
        return Self.loadCodable(SpacePrivacySettings.self, key: keyForPrivacySettings(for: containerId))
            ?? legacyPrivacySettings
    }

    func setPrivacySettings(_ value: SpacePrivacySettings, for containerId: UUID) {
        saveCodable(value, forKey: keyForPrivacySettings(for: containerId))
        containerSettingsRevision &+= 1
    }

    func notifySpacePrivacySettingsChanged(for containerId: UUID) {
        NotificationCenter.default.post(
            name: .spacePrivacySettingsChanged,
            object: nil,
            userInfo: ["containerId": containerId]
        )
    }

    func removeContainerSettings(for containerId: UUID) {
        defaults.removeObject(forKey: keyForDefaultSearch(for: containerId))
        defaults.removeObject(forKey: keyForDefaultAI(for: containerId))
        defaults.removeObject(forKey: keyForAutoClear(for: containerId))
        defaults.removeObject(forKey: keyForPrivacySettings(for: containerId))
        containerSettingsRevision &+= 1
    }

    /// The Home button's target. A bare host gets `https://`, and anything that does not
    /// parse falls back to the built-in page rather than navigating nowhere.
    var homePageURL: URL {
        let trimmed = homePageURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .oraHome }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)") ?? .oraHome
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

    // MARK: - Permissions

    func upsertSitePermission(_ permission: SitePermissionSettings) {
        var copy = sitePermissions
        copy[permission.host] = permission
        sitePermissions = copy
    }

    func removeSitePermission(host: String) {
        var copy = sitePermissions
        copy.removeValue(forKey: host)
        sitePermissions = copy
    }

    // MARK: - Custom Search Engines

    func addCustomSearchEngine(_ engine: CustomSearchEngine) {
        var engines = customSearchEngines
        engines.append(engine)
        customSearchEngines = engines
    }

    // MARK: - Ad block filter catalog

    func adBlockFilterList(id: String) -> FilterListRecord? {
        adBlockFilterLists.first { $0.id == id }
    }

    func setAdBlockFilterLists(_ records: [FilterListRecord]) {
        adBlockFilterLists = FilterListCatalogService.shared.normalizedRecords(from: records)
    }

    func upsertAdBlockFilterList(_ record: FilterListRecord) {
        var records = adBlockFilterLists
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        adBlockFilterLists = FilterListCatalogService.shared.normalizedRecords(from: records)
    }

    func removeAdBlockFilterList(id: String) {
        adBlockFilterLists = FilterListCatalogService.shared.normalizedRecords(
            from: adBlockFilterLists.filter { $0.id != id }
        )
    }

    func removeCustomSearchEngine(withId id: String) {
        customSearchEngines = customSearchEngines.filter { $0.id != id }
    }

    func updateCustomSearchEngine(_ engine: CustomSearchEngine) {
        var engines = customSearchEngines
        if let index = engines.firstIndex(where: { $0.id == engine.id }) {
            engines[index] = engine
            customSearchEngines = engines
        }
    }

    // MARK: - Custom Keyboard Shortcuts

    func setCustomKeyboardShortcut(id: String, keyChord: KeyChord) {
        var shortcuts = customKeyboardShortcuts
        shortcuts[id] = keyChord
        customKeyboardShortcuts = shortcuts
    }

    func removeCustomKeyboardShortcut(id: String) {
        var shortcuts = customKeyboardShortcuts
        shortcuts.removeValue(forKey: id)
        customKeyboardShortcuts = shortcuts
    }

    // MARK: - Password prompts

    func suppressPasswordSavePrompts(for host: String) {
        let normalizedHost = PasswordManagerService.normalizeHost(host)
        guard !normalizedHost.isEmpty else { return }
        suppressedPasswordSavePromptHosts.insert(normalizedHost)
    }

    func allowsPasswordSavePrompts(for host: String) -> Bool {
        let normalizedHost = PasswordManagerService.normalizeHost(host)
        guard !normalizedHost.isEmpty else { return true }
        return !suppressedPasswordSavePromptHosts.contains(normalizedHost)
    }

    // MARK: - Codable helpers

    private func saveCodable(_ value: some Encodable, forKey key: String) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadCodable<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Normalization helpers

    private static func normalizeTimeout(
        _ raw: TimeInterval,
        defaultSeconds: TimeInterval,
        supported: [TimeInterval]
    ) -> TimeInterval {
        let value: TimeInterval = raw == 0 ? defaultSeconds : raw

        if supported.contains(value) {
            return value
        }

        return supported.min { lhs, rhs in
            abs(lhs - value) < abs(rhs - value)
        } ?? defaultSeconds
    }

    private var legacyPrivacySettings: SpacePrivacySettings {
        SpacePrivacySettings(
            blockThirdPartyTrackers: blockThirdPartyTrackers,
            blockFingerprinting: blockFingerprinting,
            adBlocking: adBlocking,
            cookiesPolicy: cookiesPolicy
        )
    }
}
