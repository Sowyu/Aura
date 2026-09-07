import SwiftUI

struct OraCommands: Commands {
    // Rebinding a chord must invalidate the menu that reads currentChord.
    @StateObject private var shortcuts = CustomKeyboardShortcutManager.shared
    @StateObject private var appearanceManager = AppearanceManager.shared
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
                showLauncher()
            }.keyboardShortcut(KeyboardShortcuts.Tabs.new.keyboardShortcut)

            // MARK: - Open local files

            Button("Open File\u{2026}") {
                let urls = FileOpenService.shared.chooseFiles()
                guard !urls.isEmpty else { return }
                // Through the delegate, so a file opens exactly the way one dropped on the
                // dock icon does, including the open-in-new-window preference.
                (NSApp.delegate as? AppDelegate)?.handleIncomingURLs(urls)
            }
            .keyboardShortcut(KeyboardShortcuts.Files.open.keyboardShortcut)

            Divider()

            ImportDataButton()

            Divider()

            Button("Close Tab") {
                NSApp.keyWindow.map { window in
                    if AppDelegate.isBrowserWindow(window) {
                        NotificationCenter.default.post(name: .closeActiveTab, object: window)
                    } else {
                        window.performClose(nil)
                    }
                }
            }.keyboardShortcut(KeyboardShortcuts.Tabs.close.keyboardShortcut)

            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut(KeyboardShortcuts.Window.close.keyboardShortcut)

        }

        CommandGroup(after: .undoRedo) {
            Button("Find in Page") {
                NotificationCenter.default.post(name: .findInPage, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Edit.find.keyboardShortcut)

            Button(KeyboardShortcuts.Edit.findNext.name) {
                NotificationCenter.default.post(name: .findNext, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Edit.findNext.keyboardShortcut)

            Button(KeyboardShortcuts.Edit.findPrevious.name) {
                NotificationCenter.default.post(name: .findPrevious, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Edit.findPrevious.keyboardShortcut)

            Divider()

            Button("Copy URL") {
                NotificationCenter.default.post(name: .copyAddressURL, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Address.copyURL.keyboardShortcut)
        }

        CommandGroup(replacing: .sidebar) {
            // APPEARANCE
            Picker("Appearance", selection: Binding(
                get: { appearanceManager.appearance },
                set: { newValue in
                    appearanceManager.appearance = newValue
                    NotificationCenter.default.post(
                        name: .setAppearance,
                        object: browserWindow,
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
                NotificationCenter.default.post(name: .toggleSidebar, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.App.toggleSidebar.keyboardShortcut)

            Button(isToolbarHidden ? "Show Toolbar" : "Hide Toolbar") {
                NotificationCenter.default.post(name: .toggleToolbar, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.App.toggleToolbar.keyboardShortcut)

            Toggle("Compact Mode", isOn: Binding(
                get: { isCompactEnabled },
                set: { _ in
                    NotificationCenter.default.post(name: .toggleCompactMode, object: browserWindow)
                }
            ))
            .keyboardShortcut(KeyboardShortcuts.Window.toggleCompactMode.keyboardShortcut)

            Divider()

            // LAYOUT
            Button(sidebarPosition == .primary ? "Right Side Tabs" : "Left Side Tabs") {
                NotificationCenter.default.post(name: .toggleSidebarPosition, object: browserWindow)
            }

            Button(showFullURL ? "Hide Full URL" : "Show Full URL") {
                NotificationCenter.default.post(name: .toggleFullURL, object: browserWindow)
            }

            Divider()

            // MARK: Per-site zoom

            Button(KeyboardShortcuts.Zoom.zoomIn.name) {
                NotificationCenter.default.post(name: .zoomIn, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Zoom.zoomIn.keyboardShortcut)

            Button(KeyboardShortcuts.Zoom.zoomOut.name) {
                NotificationCenter.default.post(name: .zoomOut, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Zoom.zoomOut.keyboardShortcut)

            Button(KeyboardShortcuts.Zoom.reset.name) {
                NotificationCenter.default.post(name: .zoomReset, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Zoom.reset.keyboardShortcut)

            Divider()

            Button(KeyboardShortcuts.Privacy.toggleJavaScript.name) {
                NotificationCenter.default.post(name: .toggleSiteJavaScript, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Privacy.toggleJavaScript.keyboardShortcut)

            Divider()
        }

        // MARK: - Page tools

        CommandGroup(replacing: .saveItem) {
            // Not ⌘S: that is Toggle Sidebar, and the File menu would win the binding
            // away from it.
            Button("Save Page As…") {
                NotificationCenter.default.post(name: .savePageAs, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Page.save.keyboardShortcut)

            Button("Save Screenshot…") {
                NotificationCenter.default.post(name: .savePageScreenshot, object: browserWindow)
            }
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut(KeyboardShortcuts.Window.fullscreen.keyboardShortcut)

            Button("Reader") {
                NotificationCenter.default.post(name: .showReaderMode, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Page.reader.keyboardShortcut)

            Button("View Source") {
                NotificationCenter.default.post(name: .viewPageSource, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Page.source.keyboardShortcut)
        }

        CommandMenu("Navigation") {
            Button("Reload Page") {
                NotificationCenter.default.post(name: .reloadPage, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Navigation.reload.keyboardShortcut)

            // MARK: Hard reload

            Button(KeyboardShortcuts.Navigation.hardReload.name) {
                NotificationCenter.default.post(name: .hardReloadPage, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Navigation.hardReload.keyboardShortcut)

            // No chord: ⇧⌘R is the hard reload every other browser puts there, and this
            // item does the heavier thing (it empties the whole host's cache first).
            Button("Clear Cache & Reload") {
                NotificationCenter.default.post(name: .clearCacheAndReload, object: browserWindow)
            }

            Button("Clear Cookies & Reload") {
                NotificationCenter.default.post(name: .clearCookiesAndReload, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Page.clearCookies.keyboardShortcut)

            Divider()

            Button("Back") {
                NotificationCenter.default.post(name: .goBack, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Navigation.back.keyboardShortcut)

            Button("Forward") {
                NotificationCenter.default.post(name: .goForward, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Navigation.forward.keyboardShortcut)
        }

        CommandMenu("Tabs") {
            Button("Reopen Closed Tab") {
                NotificationCenter.default.post(name: .restoreLastTab, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Tabs.restore.keyboardShortcut)

            Divider()

            Button("Pin Tab") {
                NotificationCenter.default.post(name: .togglePinTab, object: browserWindow)
            }.keyboardShortcut(KeyboardShortcuts.Tabs.pin.keyboardShortcut)

            Divider()

            Button("Next Tab") {
                NotificationCenter.default.post(name: .nextTab, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Tabs.next.keyboardShortcut)

            Button("Previous Tab") {
                NotificationCenter.default.post(name: .previousTab, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Tabs.previous.keyboardShortcut)

            Divider()

            // Quick Tab Selection (1–9)
            ForEach(1 ... 9, id: \.self) { index in
                Button("Tab \(index)") {
                    NotificationCenter.default.post(
                        name: .selectTabAtIndex,
                        object: browserWindow,
                        userInfo: ["index": index]
                    )
                }
                .keyboardShortcut(KeyboardShortcuts.Tabs.keyboardShortcut(for: index))
            }
        }

        // MARK: - Bookmarks

        CommandMenu("Bookmarks") {
            Button("Add Bookmark…") {
                NotificationCenter.default.post(name: .addBookmark, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Bookmarks.add.keyboardShortcut)

            Button("Add to Reading List") {
                NotificationCenter.default.post(name: .addToReadingList, object: browserWindow)
            }

            Divider()

            Button("Show All Bookmarks") {
                NotificationCenter.default.post(
                    name: .openSettingsTab,
                    object: browserWindow,
                    userInfo: ["tab": SettingsTab.bookmarks.rawValue]
                )
            }
            .keyboardShortcut(KeyboardShortcuts.Bookmarks.showManager.keyboardShortcut)

            Button(showBookmarksBar ? "Hide Bookmarks Bar" : "Show Bookmarks Bar") {
                NotificationCenter.default.post(name: .toggleBookmarksBar, object: browserWindow)
            }
            .keyboardShortcut(KeyboardShortcuts.Bookmarks.toggleBar.keyboardShortcut)
        }

        // Grouped so `body` stays within CommandsBuilder's ten-child buildBlock:
        // twelve top-level entries compile on SDKs with variadic builders and fail
        // on ones without, and CI's pinned Xcode is one of the latter.
        Group {
            CommandMenu("History") {
                Button("Show All History") {
                    NotificationCenter.default.post(name: .showHistoryPanel, object: browserWindow)
                }
                .keyboardShortcut(KeyboardShortcuts.History.show.keyboardShortcut)
            }

            CommandMenu("Passwords") {
                Button("Manage Passwords") {
                    openPasswordsWindow()
                }
            }

            CommandGroup(replacing: .appInfo) {
                Button("About Aura") { openSettings(.about) }
                Button("Check for Updates") {
                    NotificationCenter.default.post(
                        name: .checkForUpdates,
                        object: browserWindow
                    )
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openSettings(.lookAndFeel)
                }
                .keyboardShortcut(KeyboardShortcuts.App.preferences.keyboardShortcut)
            }
        }
    }

    // MARK: - Utility Helpers

    private var browserWindow: NSWindow? {
        (NSApp.delegate as? AppDelegate)?.getWindow()
    }

    private func showLauncher() {
        guard AppDelegate.browserWindow(in: NSApp.windows) != nil else {
            _ = WindowFactory.makeMainWindow(rootView: OraRoot(initialShowLauncher: true))
            return
        }
        NotificationCenter.default.post(name: .showLauncher, object: browserWindow)
    }

    private func openSettings(_ section: SettingsTab) {
        guard AppDelegate.browserWindow(in: NSApp.windows) != nil else {
            WindowFactory.openWindow(with: .oraSettings(section: section))
            return
        }
        NotificationCenter.default.post(
            name: .openSettingsTab, object: browserWindow,
            userInfo: ["tab": section.rawValue]
        )
    }
}
