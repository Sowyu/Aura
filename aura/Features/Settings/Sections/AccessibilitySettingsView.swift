import SwiftUI

struct AccessibilitySettingsView: View {
    @Bindable private var settings = SettingsStore.shared

    var body: some View {
        SettingsSection {
            SettingsCard(
                header: "Motion",
                description: "Turns off the sidebar, toolbar, launcher and menu animations. "
                    + "Nothing moves; panels appear where they land."
            ) {
                Toggle("Reduce motion", isOn: $settings.reduceMotion)
            }

            SettingsCard(
                header: "Minimum font size",
                description: "Web pages will not render text smaller than this. "
                    + "Applies to pages loaded after the change."
            ) {
                HStack(spacing: 12) {
                    Slider(value: $settings.minimumFontSize, in: 0 ... 24, step: 1)
                        .frame(maxWidth: 260)
                    Text(settings.minimumFontSize == 0 ? "Off" : "\(Int(settings.minimumFontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .leading)
                }
            }

            SettingsCard(
                header: "Scroll bars",
                description: "Keeps scroll bars on screen instead of letting them fade out. "
                    + "Takes effect the next time Aura starts."
            ) {
                Toggle("Always show scroll bars", isOn: $settings.alwaysShowScrollBars)
            }
        }
    }
}
