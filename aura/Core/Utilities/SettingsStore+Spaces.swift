import Foundation

/// Per-space (per `TabContainer`) settings. These live only in `UserDefaults` under a
/// key built from the container's UUID, so no stored property on `SettingsStore`
/// changes when one is written. Observation has no `objectWillChange`, so the getters
/// read `containerSettingsRevision` and the setters bump it: same invalidation, same
/// granularity as the hand-rolled sends it replaces.
extension SettingsStore {
    private func keyForDefaultSearch(for containerId: UUID) -> String {
        "settings.container.\(containerId.uuidString).defaultSearch"
    }

    private func keyForDefaultAI(for containerId: UUID) -> String {
        "settings.container.\(containerId.uuidString).defaultAI"
    }

    private func keyForAutoClear(for containerId: UUID) -> String {
        "settings.container.\(containerId.uuidString).autoClearTabsAfter"
    }

    private func keyForPrivacySettings(for containerId: UUID) -> String {
        "settings.container.\(containerId.uuidString).privacy"
    }

    // MARK: - Search

    func defaultSearchEngineId(for containerId: UUID) -> String? {
        _ = containerSettingsRevision
        return defaults.string(forKey: keyForDefaultSearch(for: containerId))
    }

    func setDefaultSearchEngineId(_ id: String?, for containerId: UUID) {
        defaults.set(id, forKey: keyForDefaultSearch(for: containerId))
        containerSettingsRevision &+= 1
    }

    func defaultAIEngineId(for containerId: UUID) -> String? {
        _ = containerSettingsRevision
        return defaults.string(forKey: keyForDefaultAI(for: containerId))
    }

    func setDefaultAIEngineId(_ id: String?, for containerId: UUID) {
        defaults.set(id, forKey: keyForDefaultAI(for: containerId))
        containerSettingsRevision &+= 1
    }

    // MARK: - Auto-clear

    func autoClearTabsAfter(for containerId: UUID) -> AutoClearTabsAfter {
        _ = containerSettingsRevision
        guard let raw = defaults.string(forKey: keyForAutoClear(for: containerId)),
              let value = AutoClearTabsAfter(rawValue: raw)
        else { return .never }
        return value
    }

    func setAutoClearTabsAfter(_ value: AutoClearTabsAfter, for containerId: UUID) {
        defaults.set(value.rawValue, forKey: keyForAutoClear(for: containerId))
        containerSettingsRevision &+= 1
    }

    // MARK: - Privacy

    /// Called once per new tab and on every content-rule rebuild, so the decoded blob is
    /// memoised; the write paths below drop the entry they touch. A space with nothing
    /// stored yet falls back to the global toggles and is deliberately not cached, so a
    /// change to those toggles still reaches it.
    func privacySettings(for containerId: UUID) -> SpacePrivacySettings {
        _ = containerSettingsRevision
        if let cached = privacySettingsCache[containerId] { return cached }
        guard let stored = Self.loadCodable(
            SpacePrivacySettings.self,
            key: keyForPrivacySettings(for: containerId)
        ) else { return legacyPrivacySettings }
        privacySettingsCache[containerId] = stored
        return stored
    }

    func setPrivacySettings(_ value: SpacePrivacySettings, for containerId: UUID) {
        saveCodable(value, forKey: keyForPrivacySettings(for: containerId))
        privacySettingsCache[containerId] = value
        containerSettingsRevision &+= 1
    }

    func notifySpacePrivacySettingsChanged(for containerId: UUID) {
        NotificationCenter.default.post(
            name: .spacePrivacySettingsChanged,
            object: nil,
            userInfo: ["containerId": containerId]
        )
    }

    // MARK: - Teardown

    func removeContainerSettings(for containerId: UUID) {
        defaults.removeObject(forKey: keyForDefaultSearch(for: containerId))
        defaults.removeObject(forKey: keyForDefaultAI(for: containerId))
        defaults.removeObject(forKey: keyForAutoClear(for: containerId))
        defaults.removeObject(forKey: keyForPrivacySettings(for: containerId))
        privacySettingsCache.removeValue(forKey: containerId)
        containerSettingsRevision &+= 1
    }
}
