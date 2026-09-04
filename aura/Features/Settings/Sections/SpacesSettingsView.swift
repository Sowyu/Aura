import SwiftData
import SwiftUI

// swiftlint:disable type_body_length large_tuple
struct SpacesSettingsView: View {
    @Environment(\.theme) private var theme
    /// Creation order, so the paged space switcher lands on the same space every time.
    /// Unsorted, SwiftData returns store order, which can change after a save.
    @Query(sort: [SortDescriptor(\TabContainer.createdAt)]) var containers: [TabContainer]

    private let settings = SettingsStore.shared
    @ObservedObject private var siteRules = SiteSpaceRuleService.shared
    @State private var searchService = SearchEngineService()
    @State private var selectedContainerId: UUID?
    // The page rolls its own split layout instead of `SettingsSection`, so it has to
    // honour the accessibility scroll-bar setting itself.
    @AppStorage("a11y.alwaysShowScrollBars") private var alwaysShowScrollBars = false
    @Environment(HistoryManager.self) private var historyManager
    @Environment(ToastManager.self) private var toastManager
    @Environment(ContainerManager.self) private var containerManager

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
            .frame(width: SettingsMetrics.spaceListWidth)

            Divider()

            // Right details
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    if let container = selectedContainer {
                        SettingsCard(header: "Defaults") {
                            Grid(alignment: .leading, verticalSpacing: 12) {
                                GridRow {
                                    Text("Search engine")
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
                                    Text("AI chat")
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
                                    Text("Default container")
                                        .frame(width: 140, alignment: .leading)
                                    // The only binding between a space and a container.
                                    // New tabs in this space open in whatever is picked.
                                    Picker(
                                        "",
                                        selection: Binding(
                                            get: { container.defaultBrowsingContainer?.id },
                                            set: { newID in
                                                containerManager.setDefault(
                                                    containerManager.containers
                                                        .first { $0.id == newID },
                                                    for: container
                                                )
                                            }
                                        )
                                    ) {
                                        Text("None").tag(nil as UUID?)
                                        Divider()
                                        ForEach(containerManager.containers, id: \.id) { browsing in
                                            Text(browsing.name).tag(Optional(browsing.id))
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                GridRow {
                                    Text("Auto clear tabs")
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

                        clearDataCard(for: container)

                    } else {
                        Text("No spaces found")
                            .foregroundStyle(theme.mutedForeground)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Spacer(minLength: 0)
                }
                .padding(SettingsMetrics.gutter)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(alwaysShowScrollBars ? .visible : .automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .onAppear {
            if selectedContainerId == nil { selectedContainerId = containers.first?.id }
        }
    }

    /// The toast is the confirmation. The buttons used to latch to "Cache Cleared" and
    /// disable themselves for the rest of the session, so a second clear was impossible
    /// without closing Settings.
    private func clearDataCard(for container: TabContainer) -> some View {
        SettingsCard(header: "Clear data") {
            VStack(spacing: 8) {
                clearButton("Clear Cache") {
                    PrivacyService.clearCache(container) {
                        DispatchQueue.main.async {
                            toastManager.show("Cache cleared", icon: .system("trash"))
                        }
                    }
                }

                clearButton("Clear Cookies") {
                    PrivacyService.clearCookies(container) {
                        DispatchQueue.main.async {
                            toastManager.show("Cookies cleared", icon: .system("trash"))
                        }
                    }
                }

                clearButton("Clear History") {
                    historyManager.clearContainerHistory(container)
                    toastManager.show("History cleared", icon: .system("trash"))
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func clearButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sites pinned to this space by "Always open … in this space".
    private func siteRulesCard(for container: TabContainer) -> some View {
        let rules = siteRules.sortedRules.filter { $0.containerID == container.id }
        return SettingsCard(header: "Site rules") {
            VStack(alignment: .leading, spacing: 6) {
                if rules.isEmpty {
                    Text("No site rules for this space yet.")
                        .foregroundStyle(theme.mutedForeground)
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
            Text("These protections apply only to \(container.name). "
                + "Open tabs in this space are refreshed automatically.")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)

            Toggle(
                "Block third-party trackers",
                isOn: privacyBinding(for: container, keyPath: \.blockThirdPartyTrackers)
            )
            Toggle(
                "Block fingerprinting",
                isOn: privacyBinding(for: container, keyPath: \.blockFingerprinting)
            )

            Text("Reduces the browser and device fingerprint this space shows. "
                + "It does not block cookies or other storage on its own.")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
            Toggle(
                "Tell websites not to sell or share my data",
                isOn: privacyBinding(for: container, keyPath: \.globalPrivacyControl)
            )

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
