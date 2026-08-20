import Foundation
import SwiftData

/// Decides whether page JavaScript runs, uBlock-style: one global default plus a
/// permanent per-site override keyed by registrable domain.
///
/// Rules live in the shared Ora store. The whole table is small and read on every
/// navigation, so it is mirrored in a dictionary and only re-read when it changes.
@MainActor
final class JavaScriptPolicyService: ObservableObject {
    static let shared = JavaScriptPolicyService()

    /// Registrable domain to decision. `nil` entry means "no rule", so absence is the default.
    @Published private(set) var rules: [String: Bool] = [:]

    private var context: ModelContext?
    private var didLoad = false

    init(context: ModelContext? = nil) {
        self.context = context
        if context != nil {
            reload()
        }
    }

    // MARK: - Global default

    var blocksByDefault: Bool {
        SettingsStore.shared.blockJavaScriptByDefault
    }

    func setBlocksByDefault(_ value: Bool) {
        guard value != SettingsStore.shared.blockJavaScriptByDefault else { return }
        SettingsStore.shared.blockJavaScriptByDefault = value
        objectWillChange.send()
        notifyChange(host: nil)
    }

    // MARK: - Queries

    /// Registrable domain a rule would apply to, or nil for URLs without a host.
    func host(for url: URL) -> String? {
        registrableDomain(from: url)
    }

    /// The stored decision for this URL, or nil when the site follows the global default.
    func rule(for url: URL) -> Bool? {
        guard let host = host(for: url) else { return nil }
        return loadedRules()[host]
    }

    func isAllowed(for url: URL) -> Bool {
        // Internal pages and the launcher are Ora's own UI; they always keep their scripts.
        if url.isOraInternal { return true }
        if let override = rule(for: url) { return override }
        return !blocksByDefault
    }

    struct SiteRule: Identifiable, Hashable {
        let host: String
        let isAllowed: Bool
        var id: String { host }
    }

    /// Hosts with an explicit rule, blocked first then alphabetical, for the settings list.
    var sortedRules: [SiteRule] {
        loadedRules()
            .map { SiteRule(host: $0.key, isAllowed: $0.value) }
            .sorted { lhs, rhs in
                lhs.isAllowed == rhs.isAllowed
                    ? lhs.host < rhs.host
                    : !lhs.isAllowed
            }
    }

    // MARK: - Mutations

    func setRule(host: String, allowed: Bool) {
        let key = registrableDomain(from: host)
        guard !key.isEmpty else { return }
        _ = loadedRules()

        if let existing = fetchRule(host: key) {
            existing.isAllowed = allowed
        } else {
            context?.insert(SiteJavaScriptRule(host: key, isAllowed: allowed))
        }
        save()
        rules[key] = allowed
        notifyChange(host: key)
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
        notifyChange(host: key)
    }

    // MARK: - Storage

    /// Reads the table on first use so a browser window opening does not pay for it.
    @discardableResult
    private func loadedRules() -> [String: Bool] {
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
        let stored = (try? context.fetch(FetchDescriptor<SiteJavaScriptRule>())) ?? []
        rules = Dictionary(stored.map { ($0.host, $0.isAllowed) }, uniquingKeysWith: { _, latest in latest })
    }

    private func fetchRule(host: String) -> SiteJavaScriptRule? {
        guard let context = resolvedContext() else { return nil }
        var descriptor = FetchDescriptor<SiteJavaScriptRule>(predicate: #Predicate { $0.host == host })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func resolvedContext() -> ModelContext? {
        if let context { return context }
        // Its own context on the shared store: every window already builds one, and the
        // service is the only reader/writer of this table, so the cache stays authoritative.
        guard let container = try? ModelConfiguration.createOraContainer() else { return nil }
        let created = ModelContext(container)
        context = created
        return created
    }

    private func save() {
        try? context?.save()
    }

    private func notifyChange(host: String?) {
        NotificationCenter.default.post(
            name: .javaScriptPolicyChanged,
            object: nil,
            userInfo: host.map { ["host": $0] }
        )
    }
}
