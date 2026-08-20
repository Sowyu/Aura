import Foundation
import SwiftData

/// Firefox-style container rules: a registrable domain is pinned to a space, and every
/// main-frame navigation to that domain is steered into it.
///
/// Rules live in the shared Aura store. The table is small and read on every navigation,
/// so it is mirrored in a dictionary and only re-read when it changes.
@MainActor
final class SiteSpaceRuleService: ObservableObject {
    static let shared = SiteSpaceRuleService()

    /// Registrable domain to space id. Absence means "no rule".
    @Published private(set) var rules: [String: UUID] = [:]

    private var context: ModelContext?
    private var didLoad = false

    init(context: ModelContext? = nil) {
        self.context = context
        if context != nil {
            reload()
        }
    }

    // MARK: - Queries

    func containerID(for url: URL) -> UUID? {
        guard let host = registrableDomain(from: url) else { return nil }
        return loadedRules()[host]
    }

    func containerID(forHost host: String) -> UUID? {
        let key = registrableDomain(from: host)
        guard !key.isEmpty else { return nil }
        return loadedRules()[key]
    }

    struct SiteRule: Identifiable, Hashable {
        let host: String
        let containerID: UUID
        var id: String { host }
    }

    /// Every rule, alphabetically, for the settings list.
    var sortedRules: [SiteRule] {
        loadedRules()
            .map { SiteRule(host: $0.key, containerID: $0.value) }
            .sorted { $0.host < $1.host }
    }

    // MARK: - Mutations

    func setRule(host: String, containerID: UUID) {
        let key = registrableDomain(from: host)
        guard !key.isEmpty else { return }
        _ = loadedRules()

        if let existing = fetchRule(host: key) {
            existing.containerID = containerID
        } else {
            context?.insert(SiteSpaceRule(host: key, containerID: containerID))
        }
        save()
        rules[key] = containerID
    }

    func removeRule(host: String) {
        let key = registrableDomain(from: host)
        guard !key.isEmpty else { return }
        _ = loadedRules()

        if let existing = fetchRule(host: key) {
            context?.delete(existing)
            save()
        }
        rules.removeValue(forKey: key)
    }

    /// Called when a space is deleted, so its rules cannot strand navigations in a space
    /// that no longer exists.
    func removeRules(forContainer id: UUID) {
        _ = loadedRules()
        guard let context = resolvedContext() else { return }
        let stored = (try? context.fetch(FetchDescriptor<SiteSpaceRule>())) ?? []
        for rule in stored where rule.containerID == id {
            context.delete(rule)
        }
        save()
        rules = rules.filter { $0.value != id }
    }

    // MARK: - Storage

    /// Reads the table on first use so opening a window does not pay for it.
    @discardableResult
    private func loadedRules() -> [String: UUID] {
        if !didLoad {
            didLoad = true
            reload()
        }
        return rules
    }

    private func reload() {
        guard let context = resolvedContext() else {
            rules = [:]
            return
        }
        let stored = (try? context.fetch(FetchDescriptor<SiteSpaceRule>())) ?? []
        rules = Dictionary(stored.map { ($0.host, $0.containerID) }, uniquingKeysWith: { _, latest in latest })
    }

    private func fetchRule(host: String) -> SiteSpaceRule? {
        guard let context = resolvedContext() else { return nil }
        var descriptor = FetchDescriptor<SiteSpaceRule>(predicate: #Predicate { $0.host == host })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func resolvedContext() -> ModelContext? {
        if let context { return context }
        // Its own context on the shared store: every window already builds one, and this
        // service is the only reader and writer of the table, so the cache stays correct.
        guard let container = try? ModelConfiguration.createOraContainer() else { return nil }
        let created = ModelContext(container)
        context = created
        return created
    }

    private func save() {
        try? context?.save()
    }
}
