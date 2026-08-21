//
//  DefaultBrowserManager.swift
//  aura
//
//  Created by keni on 9/30/25.
//

import AppKit
import Combine
import CoreServices

class DefaultBrowserManager: ObservableObject {
    static let shared = DefaultBrowserManager()

    @Published var isDefault: Bool = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        updateIsDefault()
        // The handler can only change while the user is away in System Settings, so the
        // answer is re-read when Aura comes back to the front. The 1 Hz timer this
        // replaces hit LaunchServices and read a bundle plist off disk on the main
        // thread every second, for the life of the app, in `.common` mode — so it also
        // fired during scrolls and drags.
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.updateIsDefault() }
            .store(in: &cancellables)
    }

    func updateIsDefault() {
        let newValue = Self.checkIsDefault()
        if newValue != isDefault {
            isDefault = newValue
        }
    }

    static func checkIsDefault() -> Bool {
        guard let testURL = URL(string: "http://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: testURL),
              let appBundle = Bundle(url: appURL)
        else {
            return false
        }

        return appBundle.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func requestSetAsDefault() {
        guard let bundleID = Bundle.main.bundleIdentifier as CFString? else { return }
        LSSetDefaultHandlerForURLScheme("http" as CFString, bundleID)
        LSSetDefaultHandlerForURLScheme("https" as CFString, bundleID)
    }
}
