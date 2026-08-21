import SwiftData
import SwiftUI

/// Global privacy defaults: the filter-list catalog, fingerprinting, JavaScript,
/// cookies, and the one place that wipes browsing data.
struct PrivacySettingsView: View {
    @Query private var containers: [TabContainer]
    @Bindable private var settings = SettingsStore.shared
    @ObservedObject private var javaScriptPolicy = JavaScriptPolicyService.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(ToastManager.self) private var toastManager
    @Environment(DialogManager.self) private var dialogManager

    @State private var newCustomFilterListURL = ""
    @State private var clearScope: ClearScope = .allSpaces
    @State private var clearHistory = true
    @State private var clearCache = true
    @State private var clearCookies = false

    private enum ClearScope: Hashable {
        case allSpaces
        case space(UUID)
    }

    var body: some View {
        SettingsSection {
            blockingCard
            fingerprintingCard
            javaScriptCard
            cookiesCard
            clearDataCard
        }
    }

    // MARK: - Blocking

    private var blockingCard: some View {
        SettingsCard(
            header: "Ad and tracker blocking",
            description: "Lists are shared by every space. Turn individual lists on or off "
                + "per space under Spaces."
        ) {
            Toggle("Advanced blocking (scriptlets and cosmetic rules)", isOn: $settings.advancedBlockingEnabled)
            Toggle("Native request blocking (experimental)", isOn: $settings.nativeRequestBlockingEnabled)
            Text("Applies $removeparam, $redirect and the block rules Safari's format drops, "
                + "inside the web process. Takes effect on the next launch.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ForEach(settings.adBlockFilterLists.filter(\.isBuiltin)) { record in
                filterListRow(record, removable: false)
            }

            Divider()

            HStack(spacing: 10) {
                TextField("https://example.com/filter.txt", text: $newCustomFilterListURL)
                    .textFieldStyle(.roundedBorder)
                Button("Add list") { addCustomFilterList() }
                    .disabled(newCustomFilterListURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ForEach(settings.adBlockFilterLists.filter { $0.sourceKind == .custom }) { record in
                filterListRow(record, removable: true)
            }
        }
    }

    private func filterListRow(_ record: FilterListRecord, removable: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.body.weight(.medium))
                Text(record.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if removable {
                Button("Remove", role: .destructive) {
                    Task { await AdBlockService.shared.removeCustomList(id: record.id) }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var fingerprintingCard: some View {
        SettingsCard(
            header: "Fingerprinting",
            description: "The default for new spaces. Each space can override it."
        ) {
            Toggle("Block fingerprinting", isOn: $settings.blockFingerprinting)
            Toggle("Block third-party trackers", isOn: $settings.blockThirdPartyTrackers)
        }
    }

    // MARK: - JavaScript

    private var javaScriptCard: some View {
        SettingsCard(
            header: "JavaScript",
            description: "Per-site rules always win over the default and are kept until you remove them."
        ) {
            Toggle("Block JavaScript by default", isOn: Binding(
                get: { javaScriptPolicy.blocksByDefault },
                set: { javaScriptPolicy.setBlocksByDefault($0) }
            ))

            Divider()

            let rules = javaScriptPolicy.sortedRules
            if rules.isEmpty {
                Text("No site rules yet. Use the toolbar menu's JavaScript submenu on any page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    HStack(spacing: 12) {
                        Image(systemName: rule.isAllowed ? "curlybraces" : "nosign")
                            .foregroundStyle(rule.isAllowed ? Color.green : Color.red)
                        Text(rule.host)
                        Spacer()
                        Text(rule.isAllowed ? "Allowed" : "Blocked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) {
                            javaScriptPolicy.removeRule(host: rule.host)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var cookiesCard: some View {
        SettingsCard(
            header: "Cookies",
            description: "The default for new spaces. Each space keeps its own policy under Spaces."
        ) {
            Picker("Cookie policy", selection: $settings.cookiesPolicy) {
                ForEach(CookiesPolicy.allCases) { policy in
                    Text(policy.rawValue).tag(policy)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Clear browsing data

    private var clearDataCard: some View {
        SettingsCard(header: "Clear browsing data") {
            Picker("From", selection: $clearScope) {
                Text("All spaces").tag(ClearScope.allSpaces)
                ForEach(containers) { container in
                    Text(container.name).tag(ClearScope.space(container.id))
                }
            }
            .pickerStyle(.menu)

            Toggle("History", isOn: $clearHistory)
            Toggle("Cache", isOn: $clearCache)
            Toggle("Cookies (signs you out of websites)", isOn: $clearCookies)

            Button("Clear browsing data…", role: .destructive) { confirmClear() }
                .disabled(!clearHistory && !clearCache && !clearCookies)
        }
    }

    private var scopedContainers: [TabContainer] {
        switch clearScope {
        case .allSpaces: return containers
        case let .space(id): return containers.filter { $0.id == id }
        }
    }

    private func confirmClear() {
        let targets = scopedContainers
        let scopeName = targets.count == 1 ? targets[0].name : "every space"
        dialogManager.confirm(
            title: "Clear browsing data?",
            message: "This removes the selected data from \(scopeName). It cannot be undone.",
            iconImage: Image(systemName: "trash"),
            confirmLabel: "Clear",
            variant: .destructive,
            onConfirm: { performClear(in: targets) }
        )
    }

    private func performClear(in targets: [TabContainer]) {
        for container in targets {
            if clearCache { PrivacyService.clearCache(container) }
            if clearCookies { PrivacyService.clearCookies(container) }
            if clearHistory { deleteHistory(for: container) }
        }
        toastManager.show("Browsing data cleared", icon: .system("trash"))
    }

    private func deleteHistory(for container: TabContainer) {
        let containerId = container.id
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { $0.container?.id == containerId }
        )
        guard let entries = try? modelContext.fetch(descriptor) else { return }
        for entry in entries {
            modelContext.delete(entry)
        }
        try? modelContext.save()
    }

    private func addCustomFilterList() {
        let submittedURL = newCustomFilterListURL
        Task {
            do {
                let record = try await AdBlockService.shared.addCustomList(sourceURL: submittedURL)
                await MainActor.run {
                    newCustomFilterListURL = ""
                    _ = toastManager.show("Added \(record.name)", icon: .system("checkmark.circle"))
                }
            } catch {
                await MainActor.run {
                    _ = toastManager.show(error.localizedDescription, type: .error)
                }
            }
        }
    }
}
