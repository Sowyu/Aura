import AppKit
import SwiftData
import SwiftUI

/// Every decision Aura has recorded about a single site, in one table, plus the data
/// each space has stored.
struct PermissionsSettingsView: View {
    @Environment(\.theme) private var theme
    @Query private var containers: [TabContainer]
    @Bindable private var settings = SettingsStore.shared
    @ObservedObject private var javaScriptPolicy = JavaScriptPolicyService.shared
    @ObservedObject private var siteRules = SiteSpaceRuleService.shared
    @Environment(DialogManager.self) private var dialogManager
    @Environment(ToastManager.self) private var toastManager

    @State private var siteDataSpaceID: UUID?
    @State private var siteDataHosts: [String] = []
    @State private var isLoadingSiteData = false

    private static let siteDataRowLimit = 50

    private var selectedSpace: TabContainer? {
        containers.first { $0.id == siteDataSpaceID } ?? containers.first
    }

    var body: some View {
        SettingsSection {
            devicePermissionsCard
            javaScriptCard
            spaceRulesCard
            siteDataCard
        }
        .onAppear {
            if siteDataSpaceID == nil { siteDataSpaceID = containers.first?.id }
            loadSiteData()
        }
    }

    /// Camera and microphone are the whole list on purpose: they are the only requests
    /// WebKit routes through the app, so a row for location or notifications here would
    /// promise a control Aura cannot honour.
    private var devicePermissionsCard: some View {
        SettingsCard(
            header: "Camera and microphone",
            description: "Answered from the prompt a page raises, or from the site panel in the address bar."
        ) {
            let sites = settings.sitePermissions.values
                .filter { !$0.decided.isEmpty }
                .sorted { $0.host < $1.host }
            if sites.isEmpty {
                emptyRow("No site has been given a decision yet.")
            } else {
                ForEach(sites) { site in
                    ruleRow(host: site.host, detail: Self.grantSummary(site)) {
                        settings.removeSitePermission(host: site.host)
                    }
                }
            }
        }
    }

    /// "Camera allowed, microphone blocked".
    private static func grantSummary(_ site: SitePermissionSettings) -> String {
        let text = site.decided
            .map { "\($0.kind.phrase) \($0.isAllowed ? "allowed" : "blocked")" }
            .joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
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
                // Capped: a long-lived profile reports hundreds of hosts, and the card is
                // inside the page's scroll view, so every row would be laid out at once.
                ForEach(siteDataHosts.prefix(Self.siteDataRowLimit), id: \.self) { host in
                    ruleRow(host: host, detail: "Cookies and storage") {
                        clearSiteData(for: host)
                    }
                }

                if siteDataHosts.count > Self.siteDataRowLimit {
                    emptyRow("\(siteDataHosts.count - Self.siteDataRowLimit) more sites not shown. "
                        + "Clear the whole space under Spaces.")
                }
            }
        }
    }

    private func ruleRow(host: String, detail: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(host)
            Spacer()
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
            Button("Remove", role: .destructive, action: remove)
                .buttonStyle(.borderless)
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(theme.mutedForeground)
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
