import SwiftData
import SwiftUI

struct PasswordsSettingsView: View {
    @Environment(\.theme) private var theme
    @Query(sort: \TabContainer.lastAccessedAt, order: .reverse) var containers: [TabContainer]

    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        // `SettingsSection` like every other page: the bare `VStack` this replaces had no
        // scroll view, so the vault table's 320 pt floor pushed the provider card off the
        // top of a 600 pt window with no way to reach it.
        SettingsSection {
            passwordsOverview
            vaultCard
            PasswordExportCard()
        }
    }

    private var passwordsOverview: some View {
        SettingsCard {
            Text("Aura Passwords").font(.system(size: 13, weight: .semibold))

            Toggle("Enable password manager", isOn: $settings.passwordsEnabled)
            Toggle("Autofill on login forms", isOn: $settings.passwordAutofillEnabled)
                .disabled(!settings.passwordsEnabled)
            Toggle("Auto-submit after autofill", isOn: $settings.passwordAutofillSubmitEnabled)
                .disabled(
                    !settings.passwordsEnabled
                        || !settings.passwordAutofillEnabled
                )
            Toggle("Prompt to save passwords", isOn: $settings.passwordSavePromptsEnabled)
                .disabled(!settings.passwordsEnabled)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Sync passwords via iCloud", isOn: $settings.passwordSyncViaICloud)
                    .disabled(!settings.passwordsEnabled)
                Text("Off keeps saved passwords on this Mac. Credentials saved before "
                    + "changing this keep whatever they were saved with.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var vaultCard: some View {
        SettingsCard {
            PasswordVaultView(title: "Saved credentials", containers: containers, tableHeight: 320)
        }
    }
}
