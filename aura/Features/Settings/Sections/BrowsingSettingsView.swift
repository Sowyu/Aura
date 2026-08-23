import SwiftUI

/// Tab lifetime and placement, the launcher, the home page, and what Aura does on
/// launch, on quit, and when another app hands it a link. The tab cards come from
/// `TabManagementSettingsGroup`, which used to be a sibling page.
struct BrowsingSettingsView: View {
    @Bindable private var settings = SettingsStore.shared
    @StateObject private var defaultBrowserManager = DefaultBrowserManager.shared
    @State private var homePageDraft = ""
    @State private var usesCustomHomePage = false

    var body: some View {
        SettingsSection {
            if !defaultBrowserManager.isDefault {
                SettingsCard {
                    HStack {
                        Text("Make Aura the default browser.")
                        Spacer()
                        Button("Set as Default") {
                            DefaultBrowserManager.requestSetAsDefault()
                            defaultBrowserManager.updateIsDefault()
                        }
                    }
                }
            }

            TabManagementSettingsGroup()

            homePageCard

            SettingsCard(header: "Links from other apps") {
                Picker("Open them in", selection: $settings.externalLinkTarget) {
                    ForEach(ExternalLinkTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.menu)
            }

            SettingsCard(header: "Launch and quit") {
                Toggle("Reopen the tabs I had open", isOn: $settings.restoreTabsOnLaunch)
                Toggle("Ask before quitting", isOn: $settings.confirmBeforeQuit)
            }

            SettingsBackupCard()
        }
        .onAppear {
            homePageDraft = settings.homePageURLString
            usesCustomHomePage = !settings.homePageURLString.isEmpty
        }
    }

    private var homePageCard: some View {
        SettingsCard(
            header: "Home page",
            description: "Where the Home button goes. New tabs always open on aura://home."
        ) {
            Toggle("Use a custom home page", isOn: $usesCustomHomePage)

            if usesCustomHomePage {
                TextField("https://example.com", text: $homePageDraft)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .onChange(of: usesCustomHomePage) { _, isCustom in
            settings.homePageURLString = isCustom ? homePageDraft : ""
        }
        .onChange(of: homePageDraft) { _, address in
            guard usesCustomHomePage else { return }
            settings.homePageURLString = address
        }
    }
}
