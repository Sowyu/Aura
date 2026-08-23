import Foundation

extension Notification.Name {
    static let toggleSidebar = Notification.Name("ToggleSidebar")
    static let toggleSidebarPosition = Notification.Name("ToggleSidebarPosition")
    static let copyAddressURL = Notification.Name("CopyAddressURL")

    static let showLauncher = Notification.Name("ShowLauncher")
    /// Open a tab on `aura://home`. Every "New Tab" affordance posts this.
    static let newTab = Notification.Name("NewTab")
    static let closeActiveTab = Notification.Name("CloseActiveTab")
    static let restoreLastTab = Notification.Name("RestoreLastTab")
    static let findInPage = Notification.Name("FindInPage")
    static let findNext = Notification.Name("FindNext")
    static let findPrevious = Notification.Name("FindPrevious")
    static let toggleFullURL = Notification.Name("ToggleFullURL")
    static let reloadPage = Notification.Name("ReloadPage")
    /// Reload with the cache bypassed (⇧⌘R). Its own event because the window has to
    /// build a different request rather than call `reload()`.
    static let hardReloadPage = Notification.Name("HardReloadPage")
    static let goBack = Notification.Name("GoBack")
    static let goForward = Notification.Name("GoForward")
    static let togglePinTab = Notification.Name("TogglePinTab")
    static let nextTab = Notification.Name("NextTab")
    static let previousTab = Notification.Name("PreviousTab")
    static let toggleToolbar = Notification.Name("ToggleToolbar")
    /// Per-site zoom. The level belongs to the site, so the window applies it to
    /// whichever tab is in front when the shortcut arrives.
    static let zoomIn = Notification.Name("ZoomIn")
    static let zoomOut = Notification.Name("ZoomOut")
    static let zoomReset = Notification.Name("ZoomReset")
    static let selectTabAtIndex = Notification.Name("SelectTabAtIndex") // userInfo: ["index": Int]

    // Per-window settings/events
    static let setAppearance = Notification.Name("SetAppearance") // userInfo: ["appearance": String]
    static let checkForUpdates = Notification.Name("CheckForUpdates")

    /// AppDelegate → UI routing
    static let openURL = Notification.Name("OpenURL") // userInfo: ["url": URL]

    // Cache and cookies
    static let clearCacheAndReload = Notification.Name("ClearCacheAndReload")
    static let clearCookiesAndReload = Notification.Name("ClearCookiesAndReload")
    static let spacePrivacySettingsChanged = Notification.Name("SpacePrivacySettingsChanged")
    /// A per-site JavaScript rule or the global default changed. userInfo: ["host": String] when
    /// a single site changed, absent when the global default did.
    static let javaScriptPolicyChanged = Notification.Name("JavaScriptPolicyChanged")
    static let toggleSiteJavaScript = Notification.Name("ToggleSiteJavaScript")

    /// Tabs were deleted from the shared store. Every window runs its own `TabManager`
    /// and its own `ModelContext` over that one store, so a delete is invisible to the
    /// other windows until one of them says so.
    /// object: the posting `TabManager`. userInfo: ["ids": [UUID]]
    static let tabsDeleted = Notification.Name("TabsDeleted")

    // MARK: - Bookmarks

    /// Save the key window's active tab. The menu item carries no URL: the window that
    /// claims the post is the one that knows which page is in front.
    static let addBookmark = Notification.Name("AddBookmark")
    static let addToReadingList = Notification.Name("AddToReadingList")
    /// Flip the persisted bar flag. Claimed by one window even though the setting is
    /// global, so two open windows do not toggle it twice.
    static let toggleBookmarksBar = Notification.Name("ToggleBookmarksBar")
    /// A bookmark or folder changed. Every window runs its own `BookmarkStore` over the
    /// one on-disk store, so a write is invisible to the others until one of them says so.
    /// object: the posting `BookmarkStore`.
    static let bookmarksChanged = Notification.Name("BookmarksChanged")

    /// Page tools. The receiving window acts on its own active tab.
    static let savePageAs = Notification.Name("SavePageAs")
    static let savePageScreenshot = Notification.Name("SavePageScreenshot")
    static let viewPageSource = Notification.Name("ViewPageSource")
    static let showReaderMode = Notification.Name("ShowReaderMode")

    /// App lifecycle
    static let quitRequested = Notification.Name("QuitRequested")
}
