import SwiftUI

struct OraCommands: Commands {
    @AppStorage("AppAppearance") private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("ui.sidebar.hidden") private var isSidebarHidden: Bool = false
    @AppStorage("ui.sidebar.position") private var sidebarPosition: SidebarPosition = .primary
    @AppStorage("ui.toolbar.hidden") private var isToolbarHidden: Bool = false
    // Read-only mirror for the menu title; the default must match `ToolbarManager`'s
    // or a fresh profile's menu contradicts the address bar.
    @AppStorage("ui.toolbar.showfullurl") private var showFullURL: Bool = true
    @AppStorage("ui.compact.enabled") private var isCompactEnabled: Bool = false
    /// Same key and same default as `SettingsStore.showBookmarksBar`; read here only
    /// so the menu item can say which way it goes.
    @AppStorage("ui.bookmarksBar.visible") private var showBookmarksBar: Bool = true
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "normal") }
                .keyboardShortcut(KeyboardShortcuts.Window.new.keyboardShortcut)

            Button("New Private Window") { openWindow(id: "private") }
                .keyboardShortcut(KeyboardShortcuts.Window.newPrivate.keyboardShortcut)

            Button("New Tab") {
                NotificationCenter.default.post(name: .showLauncher, object: NSApp.keyWindow)
            }.keyboardShortcut(KeyboardShortcuts.Tabs.new.keyboardShortcut)

            // MARK: - Open local files (workstream 7)

            Button("Open File\u{2026}") {
                let urls = FileOpenService.shared.chooseFiles()
                guard !urls.isEmpty else { return }
                // Through the delegate, so a file opens exactly the way one dropped on the
                // dock icon does, including the open-in-new-window preference.
                (NSApp.delegate as? AppDelegate)?.handleIncomingURLs(urls)
            }
            .keyboardShortcut(KeyboardShortcuts.Files.open.keyboardShortcut)

            // MARK: - End open local files

            Divider()

            ImportDataButton()

            Divider()

            Button("Close Tab") {
                NotificationCenter.default.post(name: .closeActiveTab, object: NSApp.keyWindow)
            }.keyboardShortcut(KeyboardShortcuts.Tabs.close.keyboardShortcut)

            Button("Close Window") {
                if let keyWindow = NSApp.keyWindow, ["Settings", "Passwords"].contains(keyWindow.title) {
                    keyWindow.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled({
                guard let keyWindow = NSApp.keyWindow else { return true }
                return !["Settings", "Passwords"].contains(keyWindow.title)
            }())
        }

        CommandGroup(after: .undoRedo) {
            Button("Find in Page") {
                NotificationCenter.default.post(name: .findInPage, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Edit.find.keyboardShortcut)

            Button(KeyboardShortcuts.Edit.findNext.name) {
                NotificationCenter.default.post(name: .findNext, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Edit.findNext.keyboardShortcut)

            Button(KeyboardShortcuts.Edit.findPrevious.name) {
                NotificationCenter.default.post(name: .findPrevious, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Edit.findPrevious.keyboardShortcut)

            Divider()

            Button("Copy URL") {
                NotificationCenter.default.post(name: .copyAddressURL, object: nil)
            }
            .keyboardShortcut(KeyboardShortcuts.Address.copyURL.keyboardShortcut)
        }

        CommandGroup(replacing: .sidebar) {
            // APPEARANCE
            Picker("Appearance", selection: Binding(
                get: { AppAppearance(rawValue: appearanceRaw) ?? .system },
                set: { newValue in
                    appearanceRaw = newValue.rawValue
                    NotificationCenter.default.post(
                        name: .setAppearance,
                        object: NSApp.keyWindow,
                        userInfo: ["appearance": newValue.rawValue]
                    )
                }
            )) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }

            Divider()

            // VISIBILITY
            Button(isSidebarHidden ? "Show Sidebar" : "Hide Sidebar") {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            }
            .keyboardShortcut(KeyboardShortcuts.App.toggleSidebar.keyboardShortcut)

            Button(isToolbarHidden ? "Show Toolbar" : "Hide Toolbar") {
                NotificationCenter.default.post(name: .toggleToolbar, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.App.toggleToolbar.keyboardShortcut)

            Toggle("Compact Mode", isOn: Binding(
                get: { isCompactEnabled },
                set: { _ in
                    NotificationCenter.default.post(name: .toggleCompactMode, object: NSApp.keyWindow)
                }
            ))
            .keyboardShortcut(KeyboardShortcuts.Window.toggleCompactMode.keyboardShortcut)

            Divider()

            // LAYOUT
            Button(sidebarPosition == .primary ? "Right Side Tabs" : "Left Side Tabs") {
                NotificationCenter.default.post(name: .toggleSidebarPosition, object: nil)
            }

            Button(showFullURL ? "Hide Full URL" : "Show Full URL") {
                NotificationCenter.default.post(name: .toggleFullURL, object: NSApp.keyWindow)
            }

            Divider()

            // MARK: Per-site zoom

            Button(KeyboardShortcuts.Zoom.zoomIn.name) {
                NotificationCenter.default.post(name: .zoomIn, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Zoom.zoomIn.keyboardShortcut)

            Button(KeyboardShortcuts.Zoom.zoomOut.name) {
                NotificationCenter.default.post(name: .zoomOut, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Zoom.zoomOut.keyboardShortcut)

            Button(KeyboardShortcuts.Zoom.reset.name) {
                NotificationCenter.default.post(name: .zoomReset, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Zoom.reset.keyboardShortcut)

            // MARK: End per-site zoom

            Divider()

            Button(KeyboardShortcuts.Privacy.toggleJavaScript.name) {
                NotificationCenter.default.post(name: .toggleSiteJavaScript, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Privacy.toggleJavaScript.keyboardShortcut)

            Divider()
        }

        // MARK: - Page tools (workstream 6)

        CommandGroup(replacing: .saveItem) {
            // Not ⌘S: that is Toggle Sidebar, and the File menu would win the binding
            // away from it.
            Button("Save Page As…") {
                NotificationCenter.default.post(name: .savePageAs, object: NSApp.keyWindow)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Save Screenshot…") {
                NotificationCenter.default.post(name: .savePageScreenshot, object: NSApp.keyWindow)
            }
        }

        CommandGroup(after: .sidebar) {
            Button("Reader") {
                NotificationCenter.default.post(name: .showReaderMode, object: NSApp.keyWindow)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Button("View Source") {
                NotificationCenter.default.post(name: .viewPageSource, object: NSApp.keyWindow)
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
        }

        // MARK: - End page tools

        CommandMenu("Navigation") {
            Button("Reload Page") {
                NotificationCenter.default.post(name: .reloadPage, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Navigation.reload.keyboardShortcut)

            // MARK: Hard reload (workstream 8)

            Button(KeyboardShortcuts.Navigation.hardReload.name) {
                NotificationCenter.default.post(name: .hardReloadPage, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Navigation.hardReload.keyboardShortcut)

            // No chord: ⇧⌘R is the hard reload every other browser puts there, and this
            // item does the heavier thing (it empties the whole host's cache first).
            Button("Clear Cache & Reload") {
                NotificationCenter.default.post(name: .clearCacheAndReload, object: NSApp.keyWindow)
            }

            // MARK: End hard reload

            Button("Clear Cookies & Reload") {
                NotificationCenter.default.post(name: .clearCookiesAndReload, object: NSApp.keyWindow)
            }
            .keyboardShortcut("r", modifiers: [.command, .option, .shift])

            Divider()

            Button("Back") {
                NotificationCenter.default.post(name: .goBack, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Navigation.back.keyboardShortcut)

            Button("Forward") {
                NotificationCenter.default.post(name: .goForward, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Navigation.forward.keyboardShortcut)
        }

        CommandMenu("Tabs") {
            Button("Reopen Closed Tab") {
                NotificationCenter.default.post(name: .restoreLastTab, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Tabs.restore.keyboardShortcut)

            Divider()

            Button("Pin Tab") {
                NotificationCenter.default.post(name: .togglePinTab, object: NSApp.keyWindow)
            }.keyboardShortcut(KeyboardShortcuts.Tabs.pin.keyboardShortcut)

            Divider()

            Button("Next Tab") {
                NotificationCenter.default.post(name: .nextTab, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Tabs.next.keyboardShortcut)

            Button("Previous Tab") {
                NotificationCenter.default.post(name: .previousTab, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Tabs.previous.keyboardShortcut)

            Divider()

            // Quick Tab Selection (1–9)
            ForEach(1 ... 9, id: \.self) { index in
                Button("Tab \(index)") {
                    NotificationCenter.default.post(
                        name: .selectTabAtIndex,
                        object: NSApp.keyWindow,
                        userInfo: ["index": index]
                    )
                }
                .keyboardShortcut(KeyboardShortcuts.Tabs.keyboardShortcut(for: index))
            }
        }

        // MARK: - Bookmarks

        CommandMenu("Bookmarks") {
            Button("Add Bookmark…") {
                NotificationCenter.default.post(name: .addBookmark, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Bookmarks.add.keyboardShortcut)

            Button("Add to Reading List") {
                NotificationCenter.default.post(name: .addToReadingList, object: NSApp.keyWindow)
            }

            Divider()

            Button("Show All Bookmarks") {
                NotificationCenter.default.post(
                    name: .openSettingsTab,
                    object: nil,
                    userInfo: ["tab": SettingsTab.bookmarks.rawValue]
                )
            }
            .keyboardShortcut(KeyboardShortcuts.Bookmarks.showManager.keyboardShortcut)

            Button(showBookmarksBar ? "Hide Bookmarks Bar" : "Show Bookmarks Bar") {
                NotificationCenter.default.post(name: .toggleBookmarksBar, object: NSApp.keyWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Bookmarks.toggleBar.keyboardShortcut)
        }

        // Grouped so `body` stays within CommandsBuilder's ten-child buildBlock:
        // twelve top-level entries compile on SDKs with variadic builders and fail
        // on ones without, and CI's pinned Xcode is one of the latter.
        Group {
            CommandMenu("History") {
                Button("Show All History") {
                    NotificationCenter.default.post(name: .showHistoryPanel, object: NSApp.keyWindow)
                }
                .keyboardShortcut(KeyboardShortcuts.History.show.keyboardShortcut)
            }

            CommandMenu("Passwords") {
                Button("Manage Passwords") {
                    openPasswordsWindow()
                }
            }

            CommandGroup(replacing: .appInfo) {
                Button("About Aura") { showAboutWindow() }
                Button("Check for Updates") {
                    NotificationCenter.default.post(
                        name: .checkForUpdates,
                        object: NSApp.keyWindow
                    )
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettingsTab, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    // MARK: - Utility Helpers

    private func showAboutWindow() {
        let alert = NSAlert()
        alert.messageText = "Aura Browser"
        alert.informativeText = """
        Version \(getAppVersion())

        © 2025 Aura Browser
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func getAppVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
}
