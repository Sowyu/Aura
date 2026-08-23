import Foundation
import Inject
import os.log
import SwiftData
import SwiftUI

final class PrivacyMode: ObservableObject {
    @Published var isPrivate: Bool

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
    }
}

/// What to do when the store refuses to open. Deleting it was the old answer, and it
/// cost the user every tab, space and history row; nothing here ever removes the file.
enum StoreOpenFailure {
    enum Action: Equatable {
        case retry
        case giveUp
    }

    /// One retry, because the failure that is worth retrying is a transient one (a lock
    /// held by a window still closing). A second failure is the file itself, and losing
    /// the data is worse than not launching.
    static func action(for attempt: Int) -> Action {
        attempt == 0 ? .retry : .giveUp
    }
}

struct OraRoot: View {
    @State private var appState = AppState()
    @StateObject private var keyModifierListener = KeyModifierListener()
    @StateObject private var updateService = UpdateService.shared
    @State private var mediaController: MediaController
    @State private var tabManager: TabManager
    @State private var containerManager: ContainerManager
    @State private var historyManager: HistoryManager
    @State private var bookmarkStore: BookmarkStore
    @State private var downloadManager: DownloadManager
    @StateObject private var privacyMode: PrivacyMode
    @State private var sidebarManager = SidebarManager()
    @State private var toolbarManager = ToolbarManager()
    @State private var dialogManager = DialogManager()
    private let toastManager = ToastManager.shared

    @ObserveInjection var inject

    /// Set only by `WindowFactory`, which opens a window already pointed somewhere.
    /// The scene-made windows leave it nil and open the usual launch tabs.
    private let initialURL: URL?

    let tabContext: ModelContext
    let historyContext: ModelContext
    let downloadContext: ModelContext
    @State private var window: NSWindow?
    @State private var notificationObservers: [NSObjectProtocol] = []

    /// `State(wrappedValue:)` evaluates eagerly where `StateObject` took an autoclosure,
    /// so every `OraRoot.init` builds a manager set even if SwiftUI keeps only the first.
    /// Measured: SwiftUI calls this exactly once per window, and `TabManager.init` writes
    /// to the store (it creates the first space), so a second call would matter.
    init(isPrivate: Bool = false, initialURL: URL? = nil) {
        self.initialURL = initialURL
        _privacyMode = StateObject(wrappedValue: PrivacyMode(isPrivate: isPrivate))

        let container = Self.openStore(isPrivate: isPrivate)
        let modelContext = ModelContext(container)

        self.tabContext = modelContext
        self.downloadContext = modelContext
        self.historyContext = modelContext
        _historyManager = State(
            wrappedValue: HistoryManager(
                modelContainer: container,
                modelContext: modelContext
            )
        )

        // Bookmarks are not browsing data. A page saved from a private window is saved
        // on purpose, so this store is always the on-disk one, never the in-memory
        // container the rest of a private window runs on. The shared container is cached,
        // so a normal window gets the one it already opened.
        _bookmarkStore = State(
            wrappedValue: BookmarkStore(modelContext: ModelContext(Self.openStore(isPrivate: false)))
        )

        let media = MediaController()
        _mediaController = State(wrappedValue: media)

        // Before any tab builds a web view: spaces used to be the cookie jars, and this
        // hands each one a container carrying the store identifier it already had.
        // A private window has an empty in-memory store, so there is nothing to migrate.
        if !isPrivate {
            StartupProfiler.measure("browsingContainerMigration") {
                ContainerManager.migrateSpaceStoresIfNeeded(context: modelContext)
            }
        }
        _containerManager = State(wrappedValue: ContainerManager(modelContext: modelContext))

        _tabManager = State(
            wrappedValue: StartupProfiler.measure("tabManager") {
                TabManager(
                    modelContainer: container,
                    modelContext: modelContext,
                    mediaController: media
                )
            }
        )

        _downloadManager = State(
            wrappedValue: DownloadManager(
                modelContainer: container,
                modelContext: modelContext
            )
        )
        StartupProfiler.mark("rootInit")
    }

    /// The private window asks for an in-memory store, so this path never touches the
    /// file on disk in that case either.
    private static func openStore(isPrivate: Bool) -> ModelContainer {
        var attempt = 0
        while true {
            do {
                return try StartupProfiler.measure("modelContainer") {
                    try ModelConfiguration.createOraContainer(isPrivate: isPrivate)
                }
            } catch {
                let reason = error.localizedDescription
                AuraLog.category("Store").error(
                    "Model container failed to open on attempt \(attempt, privacy: .public): \(reason, privacy: .public)"
                )
                recordStoreFailure(error, attempt: attempt)
                guard StoreOpenFailure.action(for: attempt) == .retry else {
                    fatalError("Failed to initialize ModelContainer: \(error)")
                }
                attempt += 1
            }
        }
    }

    /// The error behind a refused store, written next to the store itself. The crash
    /// report from the `fatalError` below says nothing a user could paste into an issue,
    /// and the log is gone by the time they think to look.
    private static func recordStoreFailure(_ error: Error, attempt: Int) {
        let path = URL.applicationSupportDirectory.appending(path: "Aura/last-store-error.txt")
        let text = "\(Date().ISO8601Format()) attempt \(attempt)\n\(error)\n"
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(text.utf8).write(to: path)
    }

    var body: some View {
        BrowserView()
            .background(WindowReader(window: $window))
            .background(
                WindowAccessor(
                    isFullscreen: Binding(
                        get: { appState.isFullscreen },
                        set: { newValue in appState.isFullscreen = newValue }
                    )
                )
            )
            .environment(\.window, window)
            .environment(appState)
            .environment(tabManager)
            .environment(containerManager)
            .environment(historyManager)
            .environment(bookmarkStore)
            .environment(mediaController)
            .environmentObject(keyModifierListener)
            .environmentObject(CustomKeyboardShortcutManager.shared)
            .environmentObject(AppearanceManager.shared)
            .environment(downloadManager)
            .environmentObject(updateService)
            .environmentObject(privacyMode)
            .environment(sidebarManager)
            .environment(toolbarManager)
            .environment(dialogManager)
            .environment(toastManager)
            .dialogs(manager: dialogManager)
            .modelContext(tabContext)
            .modelContext(historyContext)
            .modelContext(downloadContext)
            .withTheme()
            .enableInjection()
            .onAppear(perform: start)
            .onDisappear(perform: stop)
            .onChange(of: window) { _, newWindow in
                keyModifierListener.window = newWindow
                if let newWindow {
                    StartupProfiler.measure("extensionsWindowDidOpen") {
                        ExtensionManager.shared.windowDidOpen(
                            newWindow,
                            tabManager: tabManager,
                            isPrivate: privacyMode.isPrivate
                        )
                    }
                }
            }
    }

    // MARK: - Lifecycle

    private func start() {
        // onAppear can re-fire; registering twice would double-run every handler.
        guard notificationObservers.isEmpty else { return }

        downloadManager.toastManager = toastManager
        // The name-collision prompt goes on this window's dialog stack.
        downloadManager.dialogManager = dialogManager
        registerKeyDownHandlers()
        // Collected locally and stored once: appending to the @State array directly
        // re-invalidates the whole view on each of the two dozen registrations.
        notificationObservers = makeNotificationObservers()

        if let initialURL {
            tabManager.openTab(
                url: initialURL,
                historyManager: historyManager,
                downloadManager: downloadManager,
                focusAfterOpening: true,
                isPrivate: privacyMode.isPrivate
            )
        }

        StartupProfiler.reportFirstPaint()
        scheduleDeferredWork()
    }

    private func stop() {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        // The handlers capture this view (and its state objects); leaving them
        // registered keeps the listener's closures alive after the window closes.
        keyModifierListener.removeAllKeyDownHandlers()
    }

    /// Everything the first frame does not need. Runs after the window is on screen so
    /// none of it sits between `applicationDidFinishLaunching` and first paint.
    private func scheduleDeferredWork() {
        DispatchQueue.main.async {
            StartupProfiler.measure("builtInBlockingMigration") {
                BuiltInBlockingMigration.runIfNeeded()
            }
        }
        guard SettingsStore.shared.autoUpdateEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            updateService.checkForUpdatesInBackground()
        }
    }

    private func registerKeyDownHandlers() {
        // Dialog keyboard shortcuts (highest priority — checked first)
        keyModifierListener.registerKeyDownHandler { event in
            // Escape: dismiss top dialog
            if event.keyCode == 53, !dialogManager.dialogs.isEmpty {
                DispatchQueue.main.async { dialogManager.dismissTop() }
                return true
            }
            // Return: confirm top dialog (only if it carries a confirm action)
            if event.keyCode == 36, let onConfirm = dialogManager.dialogs.last?.onConfirm {
                DispatchQueue.main.async {
                    onConfirm()
                    dialogManager.dismissTop()
                }
                return true
            }
            return false
        }

        keyModifierListener.registerKeyDownHandler { event in
            guard !appState.isFloatingTabSwitchVisible else { return false }
            guard event.keyCode == 48, event.modifierFlags.contains(.control) else { return false }
            DispatchQueue.main.async { appState.isFloatingTabSwitchVisible = true }
            return true
        }
    }
}

// MARK: - Notification routing

/// Which windows a posted event belongs to. Every browser window mounts its own
/// `OraRoot`, so an event posted by a menu item or the app delegate has to be claimed
/// by exactly one of them.
enum WindowEventScope {
    /// The sender must be this window. Until `WindowReader` binds `window`, the key
    /// window stands in.
    case window
    /// Same, but an event posted with no sender at all is claimed when this window is
    /// the key one. Posts from a tracking `NSMenu` have no sender to offer.
    case windowOrKey
    /// This exact window and no stand-in. The quit confirmation replies to AppKit on
    /// the user's behalf, so a second root claiming it would answer for the wrong window.
    case exactWindow
    /// Every window handles it, wherever it came from.
    case anyWindow
}

@MainActor
extension WindowEventScope {
    /// Whether the window hosting this check should claim `note`.
    ///
    /// `keyWindow` is a parameter so the rule can be exercised without a running app, and
    /// so both ends of a post agree on the same stand-in. A poster whose own `\.window`
    /// is nil sends no sender at all, which is why `.windowOrKey` exists: views mounted
    /// inside an `NSHostingView` (the sidebar's page view) never get the window
    /// environment, so nil on either end has to resolve to the key window.
    func accepts(
        _ note: Notification,
        window: NSWindow?,
        keyWindow: NSWindow? = NSApp.keyWindow
    ) -> Bool {
        let sender = note.object as? NSWindow
        switch self {
        case .anyWindow:
            return true
        case .exactWindow:
            guard let window else { return false }
            return sender === window
        case .window:
            return sender === window ?? keyWindow
        case .windowOrKey:
            let target = window ?? keyWindow
            return sender == nil ? keyWindow === target : sender === target
        }
    }
}

/// One row of `OraRoot`'s routing table.
struct WindowEvent {
    let name: Notification.Name
    let scope: WindowEventScope
    let handle: (Notification) -> Void

    init(
        _ name: Notification.Name,
        _ scope: WindowEventScope = .window,
        handle: @escaping (Notification) -> Void
    ) {
        self.name = name
        self.scope = scope
        self.handle = handle
    }
}

extension OraRoot {
    /// Registers one observer per row and hands back the tokens. `stop()` removes every
    /// one of them when the window closes; nothing else keeps a strong reference, so the
    /// captured managers go with it.
    ///
    /// The scope check runs on the notification's own main-queue delivery, before any
    /// handler's `Task` hop. `NSApp.keyWindow` is the only volatile term in it and is
    /// only consulted while `window` is still nil, i.e. in the moments before
    /// `WindowReader` binds it.
    fileprivate func makeNotificationObservers() -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        return events.map { event in
            center.addObserver(forName: event.name, object: nil, queue: .main) { note in
                guard event.scope.accepts(note, window: window) else { return }
                event.handle(note)
            }
        }
    }

    /// The table. Handlers that touch main-actor state hop through a `Task`; the rest
    /// run inline on the notification's main-queue delivery.
    fileprivate var events: [WindowEvent] {
        [
            WindowEvent(.quitRequested, .exactWindow) { _ in confirmQuit() },
            WindowEvent(.showLauncher) { _ in
                Task { @MainActor in
                    guard tabManager.activeTab != nil else { return }
                    appState.showLauncher.toggle()
                }
            },
            WindowEvent(.newTab) { _ in
                Task { @MainActor in
                    tabManager.openHomeTab(
                        historyManager: historyManager,
                        downloadManager: downloadManager,
                        isPrivate: privacyMode.isPrivate
                    )
                }
            },
            WindowEvent(.closeActiveTab) { _ in
                Task { @MainActor in tabManager.closeActiveTab() }
            },
            WindowEvent(.restoreLastTab) { _ in
                Task { @MainActor in tabManager.restoreLastTab() }
            },
            WindowEvent(.findInPage) { _ in
                Task { @MainActor in
                    guard let activeTab = tabManager.activeTab else { return }
                    appState.showFinderIn = activeTab.id
                }
            },
            WindowEvent(.toggleFullURL) { _ in toolbarManager.showFullURL.toggle() },
            WindowEvent(.toggleToolbar) { _ in
                withAnimation(AnimationSettings.easeOut(0.15)) {
                    toolbarManager.isToolbarHidden.toggle()
                }
            },
            WindowEvent(.reloadPage) { _ in
                Task { @MainActor in tabManager.activeTab?.reload() }
            },
            WindowEvent(.goBack) { _ in
                Task { @MainActor in tabManager.activeTab?.goBack() }
            },
            WindowEvent(.goForward) { _ in
                Task { @MainActor in tabManager.activeTab?.goForward() }
            },
            WindowEvent(.togglePinTab) { _ in
                Task { @MainActor in
                    guard let tab = tabManager.activeTab else { return }
                    tabManager.togglePinTab(tab)
                }
            },
            WindowEvent(.nextTab) { _ in appState.isFloatingTabSwitchVisible = true },
            WindowEvent(.previousTab) { _ in appState.isFloatingTabSwitchVisible = true },
            WindowEvent(.setAppearance) { note in
                guard let raw = note.userInfo?["appearance"] as? String,
                      let mode = AppAppearance(rawValue: raw)
                else { return }
                AppearanceManager.shared.appearance = mode
            },
            WindowEvent(.checkForUpdates) { _ in updateService.checkForUpdates() },
            WindowEvent(.selectTabAtIndex) { note in
                Task { @MainActor in
                    guard let index = note.userInfo?["index"] as? Int else { return }
                    tabManager.selectTabAtIndex(index)
                }
            },
            WindowEvent(.openURL, .windowOrKey) { note in
                Task { @MainActor in
                    guard let url = note.userInfo?["url"] as? URL else { return }
                    tabManager.openTab(
                        url: url,
                        historyManager: historyManager,
                        downloadManager: downloadManager,
                        focusAfterOpening: true,
                        isPrivate: privacyMode.isPrivate
                    )
                }
            },
            WindowEvent(.openSettingsTab, .windowOrKey) { note in
                Task { @MainActor in openSettings(note) }
            },
            // A rule change repaints the badge everywhere, so every window re-reads its
            // own active tab rather than only the one that made the change.
            WindowEvent(.javaScriptPolicyChanged, .anyWindow) { note in
                Task { @MainActor in
                    guard let tab = tabManager.activeTab else { return }
                    if let changedHost = note.userInfo?["host"] as? String,
                       registrableDomain(from: tab.url) != changedHost
                    {
                        return
                    }
                    tab.reload()
                }
            },
            // Per-site zoom. The level is stored against the site, so each window steps
            // whatever tab it has in front rather than a tab the menu picked.
            WindowEvent(.zoomIn) { _ in
                Task { @MainActor in SiteZoomController.step(1, for: tabManager.activeTab) }
            },
            WindowEvent(.zoomOut) { _ in
                Task { @MainActor in SiteZoomController.step(-1, for: tabManager.activeTab) }
            },
            WindowEvent(.zoomReset) { _ in
                Task { @MainActor in SiteZoomController.reset(tabManager.activeTab) }
            },
            WindowEvent(.toggleSiteJavaScript) { _ in
                Task { @MainActor in
                    guard let url = tabManager.activeTab?.url,
                          let host = registrableDomain(from: url)
                    else { return }
                    let service = JavaScriptPolicyService.shared
                    service.setRule(host: host, allowed: !service.isAllowed(for: url))
                }
            },
            WindowEvent(.spacePrivacySettingsChanged, .anyWindow) { note in
                Task { @MainActor in
                    guard let containerId = note.userInfo?["containerId"] as? UUID else { return }
                    tabManager.refreshPrivacySettings(for: containerId)
                }
            },
            WindowEvent(.clearCacheAndReload) { _ in
                Task { @MainActor in clearSiteData(cookies: false) }
            },
            WindowEvent(.clearCookiesAndReload) { _ in
                Task { @MainActor in clearSiteData(cookies: true) }
            },
            // Bookmarks, kept together so a merge with other menu work is one hunk.
            WindowEvent(.addBookmark) { _ in
                Task { @MainActor in saveActiveTab(toReadingList: false) }
            },
            WindowEvent(.addToReadingList) { _ in
                Task { @MainActor in saveActiveTab(toReadingList: true) }
            },
            // The flag is global; one window flips it so two open windows do not toggle
            // it twice and land back where they started.
            WindowEvent(.toggleBookmarksBar) { _ in
                SettingsStore.shared.showBookmarksBar.toggle()
            },
            // Page tools (workstream 6). Every row acts on this window's active tab.
            WindowEvent(.savePageAs) { _ in
                Task { @MainActor in PageTools.savePageAs(tabManager.activeTab) }
            },
            WindowEvent(.savePageScreenshot) { _ in
                Task { @MainActor in PageTools.saveScreenshot(tabManager.activeTab) }
            },
            WindowEvent(.viewPageSource) { _ in
                Task { @MainActor in PageTools.viewSource(for: tabManager.activeTab) }
            },
            WindowEvent(.showReaderMode) { _ in
                Task { @MainActor in PageTools.reader(for: tabManager.activeTab) }
            },
            // Keyboard and navigation polish (workstream 8).
            WindowEvent(.hardReloadPage) { _ in
                Task { @MainActor in tabManager.activeTab?.browserPage?.hardReload() }
            }
        ]
    }

    // MARK: - Handlers too long for the table

    private func confirmQuit() {
        dialogManager.confirm(
            title: "Quit Aura?",
            message: "Are you sure you want to quit?",
            iconImage: Image("OraColorLogo"),
            confirmLabel: "Quit",
            variant: .destructive,
            onConfirm: { NSApp.reply(toApplicationShouldTerminate: true) },
            onCancel: { NSApp.reply(toApplicationShouldTerminate: false) },
            isQuitConfirmation: true
        )
    }

    @MainActor
    private func openSettings(_ note: Notification) {
        let section = (note.userInfo?["tab"] as? String).flatMap(SettingsTab.resolve(rawValue:))
        // Extensions moved out of Settings into their own internal page.
        guard section != .extensions else {
            tabManager.openExtensionsStore(
                historyManager: historyManager,
                downloadManager: downloadManager,
                isPrivate: privacyMode.isPrivate
            )
            return
        }
        tabManager.openSettingsTab(
            section: section,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: privacyMode.isPrivate
        )
    }

    /// ⌘D and "Add to Reading List" both read the page in front rather than being
    /// handed a URL: the menu item has no idea which window is key, and the window that
    /// claims the post does.
    @MainActor
    private func saveActiveTab(toReadingList: Bool) {
        guard let tab = tabManager.activeTab, !tab.url.isOraInternal else { return }
        let saved = toReadingList
            ? bookmarkStore.addToReadingList(title: tab.title, url: tab.url, faviconURL: tab.favicon)
            : bookmarkStore.add(title: tab.title, url: tab.url, faviconURL: tab.favicon)
        guard saved != nil else { return }
        toastManager.show(
            toReadingList ? "Added to reading list" : "Bookmark saved",
            icon: .system(toReadingList ? "eyeglasses" : "bookmark")
        )
    }

    /// Cookies and cache clear the same way and differ only in which store is emptied.
    @MainActor
    private func clearSiteData(cookies: Bool) {
        guard let activeTab = tabManager.activeTab else { return }
        let host = activeTab.url.host ?? ""
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let done = { [weak toastManager] in
            DispatchQueue.main.async {
                activeTab.reload()
                let what = cookies ? "Cookies" : "Cache"
                toastManager?.show("\(what) cleared for \(domain)", icon: .system("trash"))
            }
        }
        if cookies {
            PrivacyService.clearCookiesForHost(for: host, container: activeTab.container, completion: done)
        } else {
            PrivacyService.clearCacheForHost(for: domain, container: activeTab.container, completion: done)
        }
    }
}
