import SwiftUI

/// Spell checking, and the languages Aura tells websites it reads.
struct LanguagesSettingsView: View {
    @Environment(\.theme) private var theme
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        SettingsSection {
            SettingsCard(
                header: "Spell checking",
                description: "Checks spelling as you type in text fields on web pages, "
                    + "using the dictionaries in System Settings."
            ) {
                Toggle("Check spelling while typing", isOn: $settings.spellCheckEnabled)
            }

            preferredLanguagesCard
        }
    }

    /// WebKit builds the `Accept-Language` header from the system's preferred languages
    /// and offers no public API to override it per web view, so this list is shown as it
    /// is rather than pretending to be editable.
    private var preferredLanguagesCard: some View {
        SettingsCard(
            header: "Languages sent to websites",
            description: "Aura sends the languages you set in System Settings › General › "
                + "Language & Region, in that order. WebKit exposes no way to override this."
        ) {
            ForEach(Array(Locale.preferredLanguages.enumerated()), id: \.element) { index, identifier in
                HStack {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(theme.mutedForeground)
                    Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
                    Spacer()
                    Text(identifier)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
                }
            }

            Button("Open Language & Region…") {
                guard let url = URL(
                    string: "x-apple.systempreferences:com.apple.Localization-Settings.extension"
                ) else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }
}
