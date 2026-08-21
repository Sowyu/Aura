import AppKit
import SwiftData
import SwiftUI

/// Global privacy defaults: fingerprinting, JavaScript, cookies, and the one
/// place that wipes browsing data. Ad and tracker blocking belongs to uBlock
/// Origin, which ships preinstalled.
struct PrivacySettingsView: View {
    @Query private var containers: [TabContainer]
    @Bindable private var settings = SettingsStore.shared
    @ObservedObject private var javaScriptPolicy = JavaScriptPolicyService.shared
    @Environment(HistoryManager.self) private var historyManager
    @Environment(ToastManager.self) private var toastManager
    @Environment(DialogManager.self) private var dialogManager

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
        // Deleting the scoped space from the sidebar left the picker blank and every
        // clear a silent no-op, because nothing matched the stored id any more.
        .onChange(of: containers.map(\.id)) { _, ids in
            if case let .space(id) = clearScope, !ids.contains(id) {
                clearScope = .allSpaces
            }
        }
    }

    // MARK: - Blocking

    private var blockingCard: some View {
        SettingsCard(header: "Content blocking") {
            Text("uBlock Origin is installed and handles ad and tracker blocking. "
                + "Manage filter lists and per-site rules from its toolbar icon.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Open uBlock Origin dashboard", action: openUBlockDashboard)
                .disabled(uBlockDashboardURL == nil)
        }
    }

    /// nil until the extension engine has loaded uBlock Origin, or if the user
    /// removed it. An extension's id is the folder it was unpacked into.
    private var uBlockDashboardURL: URL? {
        ExtensionManager.shared.optionsPageURL(for: BundledExtensions.uBlockFolderName)
    }

    /// Settings can be a tab or its own window, so the tab has to be asked for by
    /// notification: only a browser window's root knows how to open one.
    private func openUBlockDashboard() {
        guard let url = uBlockDashboardURL else { return }
        var host: NSWindow?
        if #available(macOS 15.4, *) {
            host = ExtensionWindowAdapter.focusedAdapter()?.window
        }
        guard host != nil else {
            WindowFactory.openWindow(with: url)
            return
        }
        NotificationCenter.default.post(name: .openURL, object: host, userInfo: ["url": url])
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
            if clearHistory { historyManager.clearContainerHistory(container) }
        }
        toastManager.show("Browsing data cleared", icon: .system("trash"))
    }
}
