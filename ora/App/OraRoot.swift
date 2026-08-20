import Foundation
import Inject
import SwiftData
import SwiftUI

final class PrivacyMode: ObservableObject {
    @Published var isPrivate: Bool

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
    }
}

struct OraRoot: View {
    @StateObject private var appState = AppState()
    @StateObject private var keyModifierListener = KeyModifierListener()
    @StateObject private var updateService = UpdateService()
    @StateObject private var mediaController: MediaController
    @StateObject private var tabManager: TabManager
    @StateObject private var historyManager: HistoryManager
    @StateObject private var downloadManager: DownloadManager
    @StateObject private var privacyMode: PrivacyMode
    @StateObject private var sidebarManager = SidebarManager()
    @StateObject private var toolbarManager = ToolbarManager()
    @StateObject private var dialogManager = DialogManager()
    private let toastManager = ToastManager.shared

    @ObserveInjection var inject

    let tabContext: ModelContext
    let historyContext: ModelContext
    let downloadContext: ModelContext
    @State private var window: NSWindow?
    @State private var notificationObservers: [NSObjectProtocol] = []

    init(isPrivate: Bool = false) {
        _privacyMode = StateObject(wrappedValue: PrivacyMode(isPrivate: isPrivate))

        let container: ModelContainer
        let modelContext: ModelContext
        do {
            container = try ModelConfiguration.createOraContainer(isPrivate: isPrivate)
            modelContext = ModelContext(container)
        } catch {
            deleteSwiftDataStore("OraData.sqlite")
            fatalError("Failed to initialize ModelContainer: \(error)")
        }

        self.tabContext = modelContext
        self.downloadContext = modelContext
        self.historyContext = modelContext
        let historyManagerObj = StateObject(
            wrappedValue: HistoryManager(
                modelContainer: container,
                modelContext: modelContext
            )
        )
        _historyManager = historyManagerObj

        let media = MediaController()
        _mediaController = StateObject(wrappedValue: media)

        _tabManager = StateObject(
            wrappedValue: TabManager(
                modelContainer: container,
                modelContext: modelContext,
                mediaController: media
            )
        )

        _downloadManager = StateObject(
            wrappedValue: DownloadManager(
                modelContainer: container,
                modelContext: modelContext
            )
        )
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
            .environmentObject(appState)
            .environmentObject(tabManager)
            .environmentObject(historyManager)
            .environmentObject(mediaController)
            .environmentObject(keyModifierListener)
            .environmentObject(CustomKeyboardShortcutManager.shared)
            .environmentObject(AppearanceManager.shared)
            .environmentObject(downloadManager)
            .environmentObject(updateService)
            .environmentObject(privacyMode)
            .environmentObject(sidebarManager)
            .environmentObject(toolbarManager)
            .environmentObject(dialogManager)
            .environmentObject(toastManager)
            .dialogs(manager: dialogManager)
            .modelContext(tabContext)
            .modelContext(historyContext)
            .modelContext(downloadContext)
            .withTheme()
            .enableInjection()
            .onAppear {
                // onAppear can re-fire; registering twice would double-run every handler.
                guard notificationObservers.isEmpty else { return }

                // Collected locally and stored once: appending to the @State array
                // directly re-invalidates the whole view on each of the 21 registrations.
                var observers: [NSObjectProtocol] = []
                func observe(_ name: Notification.Name, using block: @escaping (Notification) -> Void) {
                    observers.append(
                        NotificationCenter.default.addObserver(
                            forName: name, object: nil, queue: .main, using: block
                        )
                    )
                }

                downloadManager.toastManager = toastManager
                Task {
                    let containerIDs = await MainActor.run {
                        (try? tabContext.fetch(FetchDescriptor<TabContainer>()))?.map(\.id) ?? []
                    }
                    await AdBlockService.shared.start(containerIDs: containerIDs)
                }

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

                    if event.keyCode == 48 {
                        if event.modifierFlags.contains(.control) {
                            DispatchQueue.main.async {
                                appState.isFloatingTabSwitchVisible = true
                            }
                            return true
                        }
                    }
                    return false
                }

                // Cmd+Q quit confirmation
                observe(.quitRequested) { note in
                    // Exact window match only: falling back to keyWindow lets a second
                    // OraRoot whose `window` isn't set yet claim the notification and
                    // reply(true) while the real target is still showing the dialog.
                    guard let window, note.object as? NSWindow === window else { return }
                    dialogManager.confirm(
                        title: "Quit Ora?",
                        message: "Are you sure you want to quit?",
                        iconImage: Image("OraColorLogo"),
                        confirmLabel: "Quit",
                        variant: .destructive,
                        onConfirm: { NSApp.reply(toApplicationShouldTerminate: true) },
                        onCancel: { NSApp.reply(toApplicationShouldTerminate: false) }
                    )
                }

                if SettingsStore.shared.autoUpdateEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        updateService.checkForUpdatesInBackground()
                    }
                }
                observe(.showLauncher) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        if tabManager.activeTab != nil {
                            appState.showLauncher.toggle()
                        }
                    }
                }
                observe(.closeActiveTab) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        tabManager.closeActiveTab()
                    }
                }
                observe(.restoreLastTab) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        tabManager.restoreLastTab()
                    }
                }
                observe(.findInPage) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        if let activeTab = tabManager.activeTab {
                            appState.showFinderIn = activeTab.id
                        }
                    }
                }
                observe(.toggleFullURL) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    toolbarManager.showFullURL.toggle()
                }
                observe(.toggleToolbar) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        toolbarManager.isToolbarHidden.toggle()
                    }
                }
                observe(.reloadPage) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        tabManager.activeTab?.reload()
                    }
                }
                observe(.goBack) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        tabManager.activeTab?.goBack()
                    }
                }
                observe(.goForward) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        tabManager.activeTab?.goForward()
                    }
                }
                observe(.togglePinTab) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        if let tab = tabManager.activeTab {
                            tabManager.togglePinTab(tab)
                        }
                    }
                }
                observe(.nextTab) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    appState.isFloatingTabSwitchVisible = true
                }
                observe(.previousTab) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    appState.isFloatingTabSwitchVisible = true
                }
                observe(.setAppearance) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    if let raw = note.userInfo?["appearance"] as? String,
                       let mode = AppAppearance(rawValue: raw)
                    {
                        AppearanceManager.shared.appearance = mode
                    }
                }
                observe(.checkForUpdates) { note in
                    guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                    updateService.checkForUpdates()
                }
                observe(.selectTabAtIndex) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        if let index = note.userInfo?["index"] as? Int {
                            tabManager.selectTabAtIndex(index)
                        }
                    }
                }
                observe(.openURL) { note in
                    Task { @MainActor in
                        let targetWindow = window ?? NSApp.keyWindow
                        if let sender = note.object as? NSWindow {
                            guard sender === targetWindow else { return }
                        } else {
                            guard NSApp.keyWindow === targetWindow else { return }
                        }
                        guard let url = note.userInfo?["url"] as? URL else { return }
                        tabManager.openTab(
                            url: url,
                            historyManager: historyManager,
                            downloadManager: downloadManager,
                            focusAfterOpening: true,
                            isPrivate: privacyMode.isPrivate
                        )
                    }
                }

                observe(.openSettingsTab) { note in
                    Task { @MainActor in
                        guard NSApp.keyWindow === window ?? NSApp.keyWindow else { return }
                        let section = (note.userInfo?["tab"] as? String)
                            .flatMap(SettingsTab.init(rawValue:))
                        tabManager.openSettingsTab(
                            section: section,
                            historyManager: historyManager,
                            downloadManager: downloadManager,
                            isPrivate: privacyMode.isPrivate
                        )
                    }
                }

                observe(.spacePrivacySettingsChanged) { note in
                    Task { @MainActor in
                        guard let containerId = note.userInfo?["containerId"] as? UUID else { return }
                        tabManager.refreshPrivacySettings(for: containerId)
                    }
                }

                // Clear cache and reload
                observe(.clearCacheAndReload) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }
                        if let activeTab = tabManager.activeTab {
                            let host = activeTab.url.host ?? ""
                            let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                            PrivacyService
                                .clearCacheForHost(
                                    for: domain,
                                    container: activeTab.container
                                ) { [weak toastManager] in
                                    DispatchQueue.main.async {
                                        activeTab.reload()
                                        toastManager?.show("Cache cleared for \(domain)", icon: .system("trash"))
                                    }
                                }
                        }
                    }
                }

                // Clear cookies and reload
                observe(.clearCookiesAndReload) { note in
                    Task { @MainActor in
                        guard note.object as? NSWindow === window ?? NSApp.keyWindow else { return }

                        if let activeTab = tabManager.activeTab {
                            let host = activeTab.url.host ?? ""
                            let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                            PrivacyService
                                .clearCookiesForHost(
                                    for: host,
                                    container: activeTab.container
                                ) { [weak toastManager] in
                                    DispatchQueue.main.async {
                                        activeTab.reload()
                                        toastManager?.show("Cookies cleared for \(domain)", icon: .system("trash"))
                                    }
                                }
                        }
                    }
                }

                notificationObservers = observers
            }
            .onDisappear {
                notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
                notificationObservers.removeAll()
                // The handlers capture this view (and its state objects); leaving them
                // registered keeps the listener's closures alive after the window closes.
                keyModifierListener.removeAllKeyDownHandlers()
            }
            .onChange(of: window) { _, newWindow in
                keyModifierListener.window = newWindow
            }
    }
}
