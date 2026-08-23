import SwiftData
import SwiftUI

struct PasswordsSettingsView: View {
    @Environment(\.theme) private var theme
    @Query(sort: \TabContainer.lastAccessedAt, order: .reverse) var containers: [TabContainer]

    @Bindable private var settings = SettingsStore.shared
    private let providers = PasswordManagerProviderRegistry.shared

    private var selectedProvider: PasswordManagerProviderDescriptor {
        providers.descriptor(for: settings.passwordManagerProvider)
    }

    var body: some View {
        // `SettingsSection` like every other page: the bare `VStack` this replaces had no
        // scroll view, so the vault table's 320 pt floor pushed the provider card off the
        // top of a 600 pt window with no way to reach it.
        SettingsSection {
            passwordsOverview
            vaultCard
            if selectedProvider.usesBuiltInVault {
                PasswordExportCard()
            }
        }
    }

    private var passwordsOverview: some View {
        SettingsCard {
            HStack(alignment: .top) {
                Text("Password manager")
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Picker("", selection: $settings.passwordManagerProvider) {
                        ForEach(providers.providers) { provider in
                            Text(provider.title).tag(provider.kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()

                    Text(selectedProvider.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(selectedProvider.isAvailable ? theme.mutedForeground : theme.warning)
                }
            }

            Toggle("Enable password manager", isOn: $settings.passwordsEnabled)
            Toggle("Autofill on login forms", isOn: $settings.passwordAutofillEnabled)
                .disabled(!settings.passwordsEnabled)
            Toggle("Auto-submit after autofill", isOn: $settings.passwordAutofillSubmitEnabled)
                .disabled(
                    !settings.passwordsEnabled
                        || !settings.passwordAutofillEnabled
                        || !selectedProvider.usesBuiltInOverlay
                )
            Toggle("Prompt to save passwords", isOn: $settings.passwordSavePromptsEnabled)
                .disabled(!settings.passwordsEnabled || !selectedProvider.usesBuiltInVault)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Sync passwords via iCloud", isOn: $settings.passwordSyncViaICloud)
                    .disabled(!settings.passwordsEnabled || !selectedProvider.usesBuiltInVault)
                Text("Off keeps saved passwords on this Mac. Credentials saved before "
                    + "changing this keep whatever they were saved with.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !selectedProvider.isAvailable {
                Text("\(selectedProvider.title) is not yet integrated.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
            }
        }
    }

    /// The vault itself is `PasswordVaultView`, shared with the standalone Passwords
    /// window. A provider that is not the built-in vault has nothing to show yet.
    @ViewBuilder
    private var vaultCard: some View {
        if selectedProvider.usesBuiltInVault {
            SettingsCard {
                PasswordVaultView(
                    title: "Saved credentials",
                    containers: containers,
                    tableHeight: 320
                )
            }
        } else {
            SettingsCard(header: selectedProvider.title) {
                Text("\(selectedProvider.title) integration coming soon.")
                    .foregroundStyle(theme.mutedForeground)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }
        }
    }
}
