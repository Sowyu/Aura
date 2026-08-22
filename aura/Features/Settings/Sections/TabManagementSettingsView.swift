import SwiftUI

/// How long tabs stay live, how many may be live at once, and where new ones land.
struct TabManagementSettingsView: View {
    @Bindable private var settings = SettingsStore.shared

    private static let timeouts: [(label: String, seconds: TimeInterval)] = [
        ("1 hour", 60 * 60),
        ("6 hours", 6 * 60 * 60),
        ("12 hours", 12 * 60 * 60),
        ("1 day", 24 * 60 * 60),
        ("2 days", 2 * 24 * 60 * 60),
        ("Never", 365 * 24 * 60 * 60)
    ]

    var body: some View {
        SettingsSection {
            SettingsCard(
                header: "Keeping tabs live",
                description: "A hibernated tab keeps its row, title and scroll position, "
                    + "and reloads when you go back to it."
            ) {
                timeoutRow(title: "Suspend inactive tabs after", selection: $settings.tabAliveTimeout)
                timeoutRow(title: "Remove tabs after", selection: $settings.tabRemovalTimeout)

                HStack {
                    Text("Most live tabs at once")
                    Spacer()
                    Stepper(value: $settings.maxLiveTabs, in: 4 ... 32) {
                        Text("\(settings.maxLiveTabs)")
                            .monospacedDigit()
                    }
                    .frame(width: 100)
                }

                Toggle("Also unload tabs that are playing media", isOn: $settings.unloadMediaTabs)

                HStack {
                    Text("Tabs in the recent list")
                    Spacer()
                    Picker("", selection: $settings.maxRecentTabs) {
                        ForEach(1 ... 10, id: \.self) { number in
                            Text("\(number)").tag(number)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
            }

            SettingsCard(
                header: "Under memory pressure",
                description: settings.hibernationPreset.summary
            ) {
                HStack {
                    Text("When memory runs short")
                    Spacer()
                    Picker("", selection: $settings.hibernationPreset) {
                        ForEach(TabHibernationPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                Toggle("Unload idle tabs when Aura goes to the background", isOn: $settings.unloadTabsOnResign)
            }

            SettingsCard(header: "New tabs and folders") {
                HStack {
                    Text("New tabs open at the")
                    Spacer()
                    Picker("", selection: $settings.newTabPosition) {
                        ForEach(NewTabPosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                Toggle("New folders start collapsed", isOn: $settings.foldersCollapsedByDefault)
            }

            SettingsCard(header: "Media") {
                Toggle("Auto Picture-in-Picture on tab switch", isOn: $settings.autoPiPEnabled)
            }
        }
    }

    private func timeoutRow(title: String, selection: Binding<TimeInterval>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: selection) {
                ForEach(Self.timeouts, id: \.seconds) { timeout in
                    Text(timeout.label).tag(timeout.seconds)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
    }
}
