import AppKit
import SwiftUI

/// How Aura looks: appearance, accent, glass. Where the chrome sits lives one section
/// over, in `WindowSettingsView`.
struct LookAndFeelSettingsView: View {
    @EnvironmentObject var appearanceManager: AppearanceManager

    var body: some View {
        SettingsSection {
            SettingsCard(header: "Appearance") {
                AppearanceSelector(selection: $appearanceManager.appearance)
            }

            accentCard

            GlassSettingsCard()
        }
    }

    private var accentCard: some View {
        SettingsCard(
            header: "Accent colour",
            description: "Tints the active tab, the address bar highlight, and the launcher."
        ) {
            AccentPresetRow()
        }
    }
}

/// Where the window chrome sits, what it shows, and when it gets out of the way. Split
/// out of Look and Feel: sidebar side and compact mode are layout, not styling. It shares
/// that file because the app target lists its sources explicitly.
struct WindowSettingsView: View {
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(ToolbarManager.self) private var toolbarManager

    var body: some View {
        @Bindable var sidebar = sidebarManager
        @Bindable var toolbar = toolbarManager

        SettingsSection {
            SettingsCard(header: "Layout") {
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

            SettingsCard(
                header: "Blur",
                description: "Blurs the window behind whatever is asking for input."
            ) {
                Toggle("Blur the window behind the launcher", isOn: Binding(
                    get: { SettingsStore.shared.launcherBlur },
                    set: { SettingsStore.shared.launcherBlur = $0 }
                ))
                Toggle("Blur the window while editing the address", isOn: Binding(
                    get: { SettingsStore.shared.addressEditingBlur },
                    set: { SettingsStore.shared.addressEditingBlur = $0 }
                ))
            }

            compactCard
        }
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
