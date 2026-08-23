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
        copy.removeValue(forKey: registrableDomain(from: host))
        sitePermissions = copy
    }

    /// Grants are keyed by registrable domain, so a decision made on `mail.example.com`
    /// covers `example.com` and every other subdomain, the way Safari and Chrome do it.
    func sitePermissions(forHost host: String) -> SitePermissionSettings? {
        let key = registrableDomain(from: host)
        guard !key.isEmpty else { return nil }
        return sitePermissions[key]
    }

    /// Writes one grant. `nil` clears it, and a host left with no grants at all drops
    /// out of the map rather than staying as an empty row in the settings list.
    func setSitePermission(_ decision: Bool?, for kind: SitePermissionKind, host: String) {
        let key = registrableDomain(from: host)
        guard !key.isEmpty else { return }
        var copy = sitePermissions
        var entry = copy[key] ?? SitePermissionSettings(host: key)
        entry.set(decision, for: kind)
        if entry.isEmpty {
            copy.removeValue(forKey: key)
        } else {
            copy[key] = entry
        }
        sitePermissions = copy
    }

    /// Applies a prompt answer. An answer the user did not ask to remember changes
    /// nothing on disk; `SitePermissionResolver` owns that rule so it can be tested.
    func recordSitePermission(_ answer: SitePermissionAnswer, kinds: [SitePermissionKind], host: String) {
        let key = registrableDomain(from: host)
        guard !key.isEmpty else { return }
        let updated = SitePermissionResolver.applying(answer, kinds: kinds, host: key, to: sitePermissions)
        guard updated != sitePermissions else { return }
        sitePermissions = updated
    }

    // MARK: - Per-site zoom

    /// The level pinned to `host`, or 100% when the site has none.
    func zoomLevel(forHost host: String) -> Double {
        let key = registrableDomain(from: host)
        guard !key.isEmpty else { return SiteZoom.default }
        return siteZoomLevels[key].map(SiteZoom.clamped) ?? SiteZoom.default
    }

    /// 100% removes the entry instead of storing 1.0, so the map only ever holds sites
    /// the user actually changed.
    func setZoomLevel(_ level: Double, forHost host: String) {
        let key = registrableDomain(from: host)
        guard !key.isEmpty else { return }
        var copy = siteZoomLevels
        let clamped = SiteZoom.clamped(level)
        if clamped == SiteZoom.default {
            copy.removeValue(forKey: key)
        } else {
            copy[key] = clamped
        }
        guard copy != siteZoomLevels else { return }
        siteZoomLevels = copy
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
