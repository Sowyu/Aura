import AppKit
import Foundation

class CustomKeyboardShortcutManager: ObservableObject {
    static let shared = CustomKeyboardShortcutManager()

    @Published private(set) var customShortcuts: [String: KeyChord] = [:]

    private let settingsStore = SettingsStore.shared

    /// Ids whose command no longer exists. `developer.reloadIgnoringCache` was a second
    /// ⇧⌘R sitting next to `navigation.hardReload`; the navigation one stayed.
    ///
    /// A binding stored under a retired id has nothing left to apply to, so it is dropped
    /// on load instead of being carried forward, where it would only ever show up as a
    /// phantom collision against a chord someone sets later.
    static let retiredShortcutIDs: Set<String> = ["developer.reloadIgnoringCache"]

    /// The bindings that still belong to a command.
    static func withoutRetired(_ stored: [String: KeyChord]) -> [String: KeyChord] {
        stored.filter { !retiredShortcutIDs.contains($0.key) }
    }

    private init() {
        loadCustomShortcuts()
    }

    private func loadCustomShortcuts() {
        let stored = settingsStore.customKeyboardShortcuts
        customShortcuts = Self.withoutRetired(stored)
        for id in stored.keys where Self.retiredShortcutIDs.contains(id) {
            settingsStore.removeCustomKeyboardShortcut(id: id)
        }
    }

    func setCustomShortcut(for shortcut: KeyboardShortcutDefinition, event: NSEvent) {
        if let keyChord = KeyChord(fromEvent: event) {
            customShortcuts[shortcut.id] = keyChord
            settingsStore.setCustomKeyboardShortcut(id: shortcut.id, keyChord: keyChord)
        }
    }

    func removeCustomShortcut(for shortcut: KeyboardShortcutDefinition) {
        customShortcuts.removeValue(forKey: shortcut.id)
        settingsStore.removeCustomKeyboardShortcut(id: shortcut.id)
    }

    /// Drops every binding whose id starts with `prefix`.
    ///
    /// Uninstalling an extension has to take its command bindings with it: nothing else
    /// would ever clean them up, and reinstalling the same add-on would silently
    /// inherit keys the user set for the copy they removed.
    func removeShortcuts(withPrefix prefix: String) {
        let ids = customShortcuts.keys.filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        for id in ids {
            customShortcuts.removeValue(forKey: id)
            settingsStore.removeCustomKeyboardShortcut(id: id)
        }
    }

    func getShortcut(id: String) -> KeyChord? {
        return customShortcuts[id]
    }

    func hasCustomShortcut(for shortcut: KeyboardShortcutDefinition) -> Bool {
        return customShortcuts[shortcut.id] != nil
    }
}
