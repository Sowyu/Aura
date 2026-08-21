import AppKit
import SwiftUI

/// Everything that changes how Aura looks: appearance, accent, glass, and where the
/// window chrome sits.
struct LookAndFeelSettingsView: View {
    @EnvironmentObject var appearanceManager: AppearanceManager
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(ToolbarManager.self) private var toolbarManager
    @AppStorage(AuraAccent.key) private var accentHex = AuraAccent.systemDefault

    var body: some View {
        @Bindable var sidebar = sidebarManager
        @Bindable var toolbar = toolbarManager

        SettingsSection {
            SettingsCard {
                AppearanceSelector(selection: $appearanceManager.appearance)
            }

            accentCard

            GlassSettingsCard()

            SettingsCard(header: "Window layout") {
                HStack {
                    Text("Sidebar position")
                    Spacer()
                    Picker("", selection: $sidebar.sidebarPosition) {
                        Text("Left").tag(SidebarPosition.primary)
                        Text("Right").tag(SidebarPosition.secondary)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }

                Toggle("Show the toolbar", isOn: Binding(
                    get: { !toolbar.isToolbarHidden },
                    set: { toolbar.setHidden(!$0) }
                ))

                Toggle("Show the full URL in the address bar", isOn: $toolbar.showFullURL)
            }

            compactCard
        }
    }

    private var accentCard: some View {
        SettingsCard(
            header: "Accent colour",
            description: "Tints the active tab, the address bar highlight, and the launcher."
        ) {
            HStack(spacing: 10) {
                ForEach(AuraAccent.presets, id: \.name) { preset in
                    accentSwatch(name: preset.name, hex: preset.hex)
                }
            }
        }
    }

    private func accentSwatch(name: String, hex: String) -> some View {
        let isSelected = accentHex == hex
        let swatch = hex.isEmpty ? Theme(colorScheme: .light).accent : Color(hex: hex)
        return Button {
            accentHex = hex
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(swatch)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Circle().stroke(Color.primary.opacity(isSelected ? 0.8 : 0.15), lineWidth: 2)
                    }
                Text(name)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
        }
        .buttonStyle(.plain)
        .help(name)
    }

    /// Compact mode is the same switch the View menu flips, so it goes through
    /// `SidebarManager` rather than writing the defaults key directly.
    private var compactCard: some View {
        SettingsCard(
            header: "Compact mode",
            description: "Hides chrome until the pointer reaches the window edge."
        ) {
            Toggle("Enable compact mode", isOn: Binding(
                get: { sidebarManager.isCompactEnabled },
                set: { sidebarManager.setCompactEnabled($0, toolbar: toolbarManager) }
            ))

            HStack {
                Text("Compact mode hides")
                Spacer()
                Picker("", selection: Binding(
                    get: { sidebarManager.compactHides },
                    set: { sidebarManager.setCompactHides($0, toolbar: toolbarManager) }
                )) {
                    Text("Sidebar").tag(CompactModeHides.sidebar)
                    Text("Toolbar").tag(CompactModeHides.toolbar)
                    Text("Both").tag(CompactModeHides.both)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }
}
