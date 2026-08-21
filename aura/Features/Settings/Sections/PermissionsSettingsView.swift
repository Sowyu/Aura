import AppKit
import SwiftData
import SwiftUI

/// Every decision Aura has recorded about a single site, in one table, plus the data
/// each space has stored.
struct PermissionsSettingsView: View {
    @Query private var containers: [TabContainer]
    @ObservedObject private var javaScriptPolicy = JavaScriptPolicyService.shared
    @ObservedObject private var siteRules = SiteSpaceRuleService.shared
    @Environment(DialogManager.self) private var dialogManager
    @Environment(ToastManager.self) private var toastManager

    @State private var siteDataSpaceID: UUID?
    @State private var siteDataHosts: [String] = []
    @State private var isLoadingSiteData = false

    private var selectedSpace: TabContainer? {
        containers.first { $0.id == siteDataSpaceID } ?? containers.first
    }

    var body: some View {
        SettingsSection {
            javaScriptCard
            spaceRulesCard
            siteDataCard
        }
        .onAppear {
            if siteDataSpaceID == nil { siteDataSpaceID = containers.first?.id }
            loadSiteData()
        }
    }

    private var javaScriptCard: some View {
        SettingsCard(
            header: "JavaScript rules",
            description: "Set from the address bar menu on any page."
        ) {
            let rules = javaScriptPolicy.sortedRules
            if rules.isEmpty {
                emptyRow("No site overrides yet.")
            } else {
                ForEach(rules) { rule in
                    ruleRow(host: rule.host, detail: rule.isAllowed ? "JavaScript allowed" : "JavaScript blocked") {
                        javaScriptPolicy.removeRule(host: rule.host)
                    }
                }
            }
        }
    }

    private var spaceRulesCard: some View {
        SettingsCard(
            header: "Sites pinned to a space",
            description: "Set with the tab menu: Always open in this space."
        ) {
            let rules = siteRules.sortedRules
            if rules.isEmpty {
                emptyRow("No sites are pinned to a space.")
            } else {
                ForEach(rules) { rule in
                    let name = containers.first { $0.id == rule.containerID }?.name ?? "Unknown space"
                    ruleRow(host: rule.host, detail: "Opens in \(name)") {
                        siteRules.removeRule(host: rule.host)
                    }
                }
            }
        }
    }

    private var siteDataCard: some View {
        SettingsCard(
            header: "Site data",
            description: "Cookies and storage kept by each space. "
                + "WebKit does not report per-site sizes."
        ) {
            Picker("Space", selection: Binding(
                get: { siteDataSpaceID ?? containers.first?.id },
                set: { newValue in
                    siteDataSpaceID = newValue
                    loadSiteData()
                }
            )) {
                ForEach(containers) { container in
                    Text(container.name).tag(Optional(container.id))
                }
            }
            .pickerStyle(.menu)

            if isLoadingSiteData {
                ProgressView().controlSize(.small)
            } else if siteDataHosts.isEmpty {
                emptyRow("No stored site data.")
            } else {
                ForEach(siteDataHosts, id: \.self) { host in
                    ruleRow(host: host, detail: "Cookies and storage") {
                        clearSiteData(for: host)
                    }
                }
            }
        }
    }

    private func ruleRow(host: String, detail: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(host)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Remove", role: .destructive, action: remove)
                .buttonStyle(.borderless)
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func loadSiteData() {
        guard let container = selectedSpace else {
            siteDataHosts = []
            return
        }
        isLoadingSiteData = true
        Task {
            let hosts = await PrivacyService.websiteDataHosts(container)
            siteDataHosts = hosts
            isLoadingSiteData = false
        }
    }

    private func clearSiteData(for host: String) {
        guard let container = selectedSpace else { return }
        dialogManager.confirm(
            title: "Clear data for \(host)?",
            message: "Cookies and storage this site kept in \(container.name) will be removed.",
            iconImage: Image(systemName: "trash"),
            confirmLabel: "Clear",
            variant: .destructive,
            onConfirm: {
                PrivacyService.clearAllData(forHost: host, container: container) {
                    DispatchQueue.main.async {
                        toastManager.show("Cleared data for \(host)", icon: .system("trash"))
                        loadSiteData()
                    }
                }
            }
        )
    }
}
