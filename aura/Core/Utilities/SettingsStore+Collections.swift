import Foundation

/// Mutators for the settings that are stored as one JSON blob apiece. Each one goes
/// through the matching stored property so its `didSet` does the writing; none of them
/// touch `UserDefaults` directly.
extension SettingsStore {
    // MARK: - Site permissions

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

    // MARK: - Custom search engines

    func addCustomSearchEngine(_ engine: CustomSearchEngine) {
        customSearchEngines.append(engine)
    }

    func removeCustomSearchEngine(withId id: String) {
        customSearchEngines = customSearchEngines.filter { $0.id != id }
    }

    func updateCustomSearchEngine(_ engine: CustomSearchEngine) {
        guard let index = customSearchEngines.firstIndex(where: { $0.id == engine.id }) else { return }
        customSearchEngines[index] = engine
    }

    // MARK: - Custom keyboard shortcuts

    func setCustomKeyboardShortcut(id: String, keyChord: KeyChord) {
        customKeyboardShortcuts[id] = keyChord
    }

    func removeCustomKeyboardShortcut(id: String) {
        customKeyboardShortcuts.removeValue(forKey: id)
    }

    // MARK: - Password save prompts

    func allowsPasswordSavePrompts(for host: String) -> Bool {
        let normalizedHost = PasswordManagerService.normalizeHost(host)
        guard !normalizedHost.isEmpty else { return true }
        return !suppressedPasswordSavePromptHosts.contains(normalizedHost)
    }
}
