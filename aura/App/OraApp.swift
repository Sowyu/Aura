import AppKit
import Foundation
import SwiftData
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable automatic window tabbing for all NSWindow instances
        NSWindow.allowsAutomaticWindowTabbing = false
        AppearanceManager.shared.updateAppearance()
        StartupProfiler.mark("didFinishLaunching")
        #if DEBUG
            // Two dylibs off disk, only ever used after the app is up. Loading them
            // inline pushed first paint out by the time it takes to mmap them.
            DispatchQueue.main.async {
                StartupProfiler.measure("injectionBundles") {
                    let resources = "/Applications/InjectionIII.app/Contents/Resources"
                    Bundle(path: "\(resources)/macOSInjection.bundle")?.load()
                    Bundle(path: "\(resources)/macOSSwiftUISupport.bundle")?.load()
                }
            }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Second ⌘Q while the confirmation is up: take it as the confirmation. The
        // parked reply is answered too, in case AppKit is still spinning on it.
        if DialogManager.isQuitConfirmationVisible {
            DialogManager.isQuitConfirmationVisible = false
            NSApp.reply(toApplicationShouldTerminate: true)
            return .terminateNow
        }

        guard SettingsStore.shared.confirmBeforeQuit else { return .terminateNow }

        // Only browser windows host the quit-confirmation observer; targeting any other
        // window (Settings, Passwords) would leave the terminateLater reply unanswered.
        let browserWindows = NSApp.windows.filter { $0.isVisible && Self.isBrowserWindow($0) }
        let targetWindow = browserWindows.first(where: \.isKeyWindow) ?? browserWindows.first
        guard let targetWindow else { return .terminateNow }
        DialogManager.isQuitConfirmationVisible = true
        NotificationCenter.default.post(name: .quitRequested, object: targetWindow)
        return .terminateLater
    }

    static func isBrowserWindow(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue else { return false }
        return identifier.hasPrefix("normal") || identifier.hasPrefix("private")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleIncomingURLs(urls)
    }

    func getWindow() -> NSWindow? {
        if let key = NSApp.keyWindow { return key }
        if let visible = NSApp.windows.first(where: { $0.isVisible }) { return visible }
        if let any = NSApp.windows.first {
            any.makeKeyAndOrderFront(nil)
            return any
        }
        return WindowFactory.makeMainWindow(rootView: OraRoot())
    }

    func handleIncomingURLs(_ urls: [URL]) {
        if SettingsStore.shared.externalLinkTarget == .newWindow {
            for url in urls {
                DispatchQueue.main.async { WindowFactory.openWindow(with: url) }
            }
            return
        }

        guard let window = getWindow() else { return }
        for url in urls {
            let userInfo: [AnyHashable: Any] = ["url": url]
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openURL, object: window, userInfo: userInfo)
            }
        }
    }
}

func deleteSwiftDataStore(_ loc: String) {
    let fileManager = FileManager.default
    let storeURL = URL.applicationSupportDirectory.appending(path: loc)
    let shmURL = storeURL.appendingPathExtension("-shm")
    let walURL = storeURL.appendingPathExtension("-wal")
    try? fileManager.removeItem(at: storeURL)
    try? fileManager.removeItem(at: shmURL)
    try? fileManager.removeItem(at: walURL)
}

@Observable
@MainActor
final class AppState {
    var showLauncher: Bool = false
    var launcherSearchText: String = ""
    var showFinderIn: UUID?
    var isFloatingTabSwitchVisible: Bool = false
    var isFullscreen: Bool = false
    var isURLBarEditing: Bool = false
    /// Window (`.global`) frames the address field reports while mounted, so the
    /// editing backdrop can cut holes for the pill and its suggestions.
    var urlFieldFrame: CGRect = .zero
    var urlSuggestionsFrame: CGRect = .zero
}

@main
struct OraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// The rename moved the data folder, so this has to run before anything opens the
    /// store. `OraRoot` makes its own container per window. It cannot be deferred for
    /// that reason; after the first launch it costs four `stat` calls and one
    /// `UserDefaults` read, which the startup log confirms as 0 ms.
    private let didMigrateLegacyData: Void = StartupProfiler.measure("legacyDataMigration") {
        LegacyDataMigrator.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup(id: "normal") {
            OraRoot()
                .frame(minWidth: 500, minHeight: 360)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])

        WindowGroup("Private", id: "private") {
            OraRoot(isPrivate: true)
                .frame(minWidth: 500, minHeight: 360)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
        .commands { OraCommands() }
    }
}
