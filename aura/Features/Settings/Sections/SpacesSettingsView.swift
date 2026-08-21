import SwiftData
import SwiftUI

// swiftlint:disable type_body_length large_tuple
struct SpacesSettingsView: View {
    private enum ClearDataAction: Hashable {
        case cache(UUID)
        case cookies(UUID)
        case history(UUID)
    }

    /// Creation order, so the paged space switcher lands on the same space every time.
    /// Unsorted, SwiftData returns store order, which can change after a save.
    @Query(sort: [SortDescriptor(\TabContainer.createdAt)]) var containers: [TabContainer]

    private let settings = SettingsStore.shared
    @ObservedObject private var siteRules = SiteSpaceRuleService.shared
    @State private var searchService = SearchEngineService()
    @State private var selectedContainerId: UUID?
    @State private var completedClearActions: Set<ClearDataAction> = []
    @Environment(\.modelContext) private var modelContext
    @Environment(ToastManager.self) private var toastManager

    private var selectedContainer: TabContainer? {
        containers.first { $0.id == selectedContainerId } ?? containers.first
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left list
            List(selection: $selectedContainerId) {
                ForEach(containers) { container in
                    HStack {
                        SpaceIconView(container: container, size: 14)
                        Text(container.name)
                    }
                    .tag(container.id)
                }
            }
            .frame(width: SettingsMetrics.sidebarWidth)

            Divider()

            // Right details
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    if let container = selectedContainer {
                        SettingsCard(header: "Defaults") {
                            Grid(alignment: .leading, verticalSpacing: 12) {
                                GridRow {
                                    Text("Search Engine")
                                        .frame(width: 140, alignment: .leading)
                                    Picker(
                                        "",
                                        selection: Binding(
                                            get: {
                                                settings.defaultSearchEngineId(for: container.id)
                                            },
                                            set: { settings.setDefaultSearchEngineId($0, for: container.id) }
                                        )
                                    ) {
                                        Text("Use Global Default").tag(nil as String?)
                                        Divider()
                                        ForEach(
                                            searchService.searchEngines.filter { !$0.isAIChat },
                                            id: \.name
                                        ) { engine in
                                            Text(engine.name).tag(Optional(engine.name))
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                GridRow {
                                    Text("AI Chat")
                                        .frame(width: 140, alignment: .leading)
                                    Picker(
                                        "",
                                        selection: Binding(
                                            get: {
                                                settings.defaultAIEngineId(for: container.id)
                                            },
                                            set: { settings.setDefaultAIEngineId($0, for: container.id) }
                                        )
                                    ) {
                                        Text("Use Global Default").tag(nil as String?)
                                        Divider()
                                        ForEach(
                                            searchService.searchEngines.filter(\.isAIChat),
                                            id: \.name
                                        ) { engine in
                                            Text(engine.name).tag(Optional(engine.name))
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                GridRow {
                                    Text("Auto Clear Tabs")
                                        .frame(width: 140, alignment: .leading)
                                    Picker(
                                        "",
                                        selection: Binding(
                                            get: { settings.autoClearTabsAfter(for: container.id) },
                                            set: { settings.setAutoClearTabsAfter($0, for: container.id) }
                                        )
                                    ) {
                                        ForEach(AutoClearTabsAfter.allCases) { value in
                                            Text(value.rawValue).tag(value)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        siteRulesCard(for: container)
                        privacySettingsCard(for: container)

                        SettingsCard(header: "Clear Data") {
                            VStack(spacing: 8) {
                                Button(
                                    clearDataButtonTitle(
                                        for: .cache(container.id),
                                        defaultTitle: "Clear Cache",
                                        completedTitle: "Cache Cleared"
                                    )
                                ) {
                                    PrivacyService.clearCache(container) {
                                        DispatchQueue.main.async {
                                            completedClearActions.insert(.cache(container.id))
                                            toastManager.show("Cache cleared", icon: .system("trash"))
                                        }
                                    }
                                }
                                .disabled(completedClearActions.contains(.cache(container.id)))
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button(
                                    clearDataButtonTitle(
                                        for: .cookies(container.id),
                                        defaultTitle: "Clear Cookies",
                                        completedTitle: "Cookies Cleared"
                                    )
                                ) {
                                    PrivacyService.clearCookies(container) {
                                        DispatchQueue.main.async {
                                            completedClearActions.insert(.cookies(container.id))
                                            toastManager.show("Cookies cleared", icon: .system("trash"))
                                        }
                                    }
                                }
                                .disabled(completedClearActions.contains(.cookies(container.id)))
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button(
                                    clearDataButtonTitle(
                                        for: .history(container.id),
                                        defaultTitle: "Clear History",
                                        completedTitle: "History Cleared"
                                    )
                                ) {
                                    if clearHistory(for: container) {
                                        completedClearActions.insert(.history(container.id))
                                        toastManager.show("History cleared", icon: .system("trash"))
                                    }
                                }
                                .disabled(completedClearActions.contains(.history(container.id)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }

                    } else {
                        Text("No spaces found")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Spacer(minLength: 0)
                }
                .padding(SettingsMetrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .onAppear {
            if selectedContainerId == nil { selectedContainerId = containers.first?.id }
        }
    }

    private func clearHistory(for container: TabContainer) -> Bool {
        let containerId = container.id
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { $0.container?.id == containerId }
        )

        do {
            let histories = try modelContext.fetch(descriptor)
            for history in histories {
                modelContext.delete(history)
            }
            try modelContext.save()
            return true
        } catch {
            print("Failed to clear history for container \(container.id): \(error.localizedDescription)")
            return false
        }
    }

    private func clearDataButtonTitle(
        for action: ClearDataAction,
        defaultTitle: String,
        completedTitle: String
    ) -> String {
        completedClearActions.contains(action) ? completedTitle : defaultTitle
    }

    /// Sites pinned to this space by "Always open … in this space".
    private func siteRulesCard(for container: TabContainer) -> some View {
        let rules = siteRules.sortedRules.filter { $0.containerID == container.id }
        return SettingsCard(header: "Site Rules") {
            VStack(alignment: .leading, spacing: 6) {
                if rules.isEmpty {
                    Text("No site rules for this space yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { rule in
                        HStack {
                            Text(rule.host)
                            Spacer()
                            Button {
                                siteRules.removeRule(host: rule.host)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop opening \(rule.host) in this space")
                        }
                    }
                }
            }
        }
    }

    private func privacySettingsCard(for container: TabContainer) -> some View {
        SettingsCard(header: "Privacy") {
            Text(
                "These protections apply only to \(container.name). Open tabs in this space are refreshed automatically."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Toggle(
                "Block third-party trackers",
                isOn: privacyBinding(for: container, keyPath: \.blockThirdPartyTrackers)
            )
            Toggle(
                "Block fingerprinting",
                isOn: privacyBinding(for: container, keyPath: \.blockFingerprinting)
            )

            Text(
                "Reduces browser and device fingerprint surface for this space. This does not block cookies or other storage by itself."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            Picker(
                "Cookies",
                selection: privacyBinding(for: container, keyPath: \.cookiesPolicy)
            ) {
                ForEach(CookiesPolicy.allCases) { policy in
                    Text(policy.rawValue).tag(policy)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    private func privacyBinding<Value>(
        for container: TabContainer,
        keyPath: WritableKeyPath<SpacePrivacySettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                settings.privacySettings(for: container.id)[keyPath: keyPath]
            },
            set: { newValue in
                var updatedSettings = settings.privacySettings(for: container.id)
                updatedSettings[keyPath: keyPath] = newValue
                settings.setPrivacySettings(updatedSettings, for: container.id)
                settings.notifySpacePrivacySettingsChanged(for: container.id)
            }
        )
    }
}

// swiftlint:enable type_body_length large_tuple
