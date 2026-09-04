import AppKit
import SwiftData
import SwiftUI

/// Global privacy defaults: fingerprinting, JavaScript, cookies, and the one
/// place that wipes browsing data. Ad and tracker blocking belongs to uBlock
/// Origin Lite, which ships preinstalled.
struct PrivacySettingsView: View {
    @Environment(\.theme) private var theme
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
            websitePrivacyCard
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
        // Full uBlock Origin installs from the switch above, and it is not
        // pre-consented, so this section has to be able to show the sheet.
        .extensionConsentPrompt()
        // A refused sheet has to take the switch back with it. The queue emptying is
        // the only signal that the answer, whichever it was, has landed.
        .onChange(of: ExtensionManager.shared.pendingConsent.isEmpty) { _, isEmpty in
            if isEmpty { BundledExtensions.applyBlockingPlan() }
        }
    }

    // MARK: - Blocking

    private var blockingCard: some View {
        SettingsCard(header: "Content blocking") {
            Text(blockerSummary)
                .font(.system(size: 13))
                .foregroundStyle(theme.mutedForeground)

            Button("Open \(activeBlockerName) dashboard", action: openUBlockDashboard)
                .disabled(uBlockDashboardURL == nil)

            Divider()

            Toggle("Full ad blocking (uBlock Origin)", isOn: Binding(
                get: { settings.extensionFullAdBlocking },
                set: { BundledExtensions.setFullBlocking($0) }
            ))
            .disabled(settings.requestBlockingUnavailable)
            Text("Routes web pages through a compatibility mode required for request-level "
                + "blocking, which is how full uBlock Origin stops requests. uBlock Origin Lite is "
                + "switched off while this is on, and extension request blocking below follows this "
                + "switch in both directions. Applies after relaunch.")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)

            // Said once, where the setting is, because the failure is otherwise
            // invisible: loads stall for the broker's timeout, extensions quietly
            // stop blocking, and in the worst case pages go blank after painting.
            if settings.requestBlockingUnavailable {
                Label(unavailableMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.destructive)
            } else if let waitingMessage {
                Text(waitingMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
            }

            Divider()

            Toggle("Extension request blocking (experimental)", isOn: Binding(
                get: { settings.extensionRequestBlocking },
                set: { settings.extensionRequestBlocking = $0 }
            ))
            Text("Experimental, and uBlock Origin Lite does not need it. That blocker stops requests "
                + "through declarativeNetRequest, which WebKit enforces on its own. This switch is for "
                + "add-ons that block the old way, through webRequest, full uBlock Origin included. "
                + "Pages then run in WebKit's Development WebContent service, which cannot hold the "
                + "process assertion it needs, because that entitlement is Apple-private, so they can "
                + "paint once and go blank. Aura checks at launch and switches back if they do. "
                + "Applies after relaunch.")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
        }
    }

    /// The blocker rule, asked once per body: which of the two is running, and whether
    /// the switch above is still waiting for something.
    private var blockingPlan: BundledExtensions.BlockingPlan {
        BundledExtensions.plan(for: BundledExtensions.blockingInputs())
    }

    private var activeBlockerName: String {
        blockingPlan.activeBlocker == .full ? "uBlock Origin" : "uBlock Origin Lite"
    }

    private var blockerSummary: String {
        "\(activeBlockerName) is installed and handles ad and tracker blocking. "
            + "Manage filter lists and per-site rules from its toolbar icon."
    }

    /// What the row says while the switch is on and full uBO is not running yet. Nil
    /// once it is, or while it is off.
    private var waitingMessage: String? {
        switch blockingPlan.pending {
        case .none:
            return nil
        case .consent:
            return "Waiting for you to review what uBlock Origin can do and allow it."
        case .relaunch:
            return "Relaunch Aura to hand blocking over to uBlock Origin."
        }
    }

    private var unavailableMessage: String {
        (settings.requestBlockingUnavailableReason
            ?? "The injected bundle did not answer when Aura checked at launch.")
            + " uBlock Origin Lite is handling blocking, and full ad blocking stays off until "
            + "Aura is relaunched."
    }

    /// nil until the extension engine has loaded the blocker that is running, or if the
    /// user removed it. An extension's id is the folder it was unpacked into.
    private var uBlockDashboardURL: URL? {
        let id = blockingPlan.activeBlocker == .full
            ? BundledExtensions.FullUBlockOrigin.folderName
            : BundledExtensions.folderID
        return ExtensionManager.shared.optionsPageURL(for: id)
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

    private var websitePrivacyCard: some View {
        SettingsCard(
            header: "Website privacy preferences",
            description: "The default for new spaces. Each space can override it."
        ) {
            Toggle("Tell websites not to sell or share my data", isOn: $settings.globalPrivacyControl)
            Text("Sends the Global Privacy Control signal: a Sec-GPC header on every page "
                + "request and navigator.globalPrivacyControl in every page. Sites that honour it "
                + "treat it as an opt-out under laws such as the CCPA. Reaches tabs opened from now on.")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
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
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
            } else {
                ForEach(rules) { rule in
                    HStack(spacing: 12) {
                        Image(systemName: rule.isAllowed ? "curlybraces" : "nosign")
                            .foregroundStyle(rule.isAllowed ? theme.success : theme.destructive)
                        Text(rule.host)
                        Spacer()
                        Text(rule.isAllowed ? "Allowed" : "Blocked")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.mutedForeground)
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
