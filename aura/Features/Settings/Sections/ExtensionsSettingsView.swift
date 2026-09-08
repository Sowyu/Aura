import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings keeps only a pointer: browsing, installing and per-extension controls all
/// live on the `aura://extensions` page, which has room for them.
struct ExtensionsSettingsView: View {
    @Environment(\.theme) private var theme
    private let extensionManager = ExtensionManager.shared
    @State private var installError: String?

    private var installedCount: Int {
        extensionManager.installedExtensions.count
    }

    private var summary: String {
        guard ExtensionManager.isSupported else {
            return "Extensions require macOS 15.4 or later."
        }
        let installed: String
        switch installedCount {
        case 0: installed = "No extensions installed yet."
        case 1: installed = "1 extension installed."
        default: installed = "\(installedCount) extensions installed."
        }
        let updates = extensionManager.installedExtensions
            .filter { extensionManager.availableUpdate(for: $0.id) != nil }
            .count
        guard updates > 0 else { return installed }
        return installed + (updates == 1 ? " 1 update available." : " \(updates) updates available.")
    }

    var body: some View {
        SettingsSection {
            SettingsCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extensions")
                            .font(.system(size: 13, weight: .semibold))
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.mutedForeground)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 8) {
                        OraButton(label: "Open extension store", variant: .secondary, size: .sm) { Self.openStore() }
                            .controlSize(.regular)
                            .fixedSize()
                            .disabled(!ExtensionManager.isSupported)
                        OraButton(label: "Install from file…", variant: .secondary, size: .sm, action: promptForFile)
                            .controlSize(.regular)
                            .fixedSize()
                            .disabled(!ExtensionManager.isSupported)
                        if extensionManager.isCheckingForUpdates {
                            ProgressView().controlSize(.small).accessibilityLabel(Text("Checking for updates"))
                        } else {
                            OraButton(label: "Check for updates", variant: .secondary, size: .sm) {
                                extensionManager.checkForUpdates(force: true)
                            }
                            .disabled(!ExtensionManager.isSupported || installedCount == 0)
                            .help("Check addons.mozilla.org for newer versions.")
                        }
                        if extensionManager.updateCheckFailed {
                            Text("Could not reach the add-on store. Try again.").foregroundStyle(theme.mutedForeground)
                        } else if let date = SettingsStore.shared.extensionUpdateLastCheck {
                            Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(theme.mutedForeground)
                        }
                    }
                }

                if let installError {
                    Text(installError)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.destructive)
                }
            }
        }
        .extensionConsentPrompt()
        .onAppear {
            if ExtensionManager.isSupported {
                extensionManager.start()
            }
        }
    }

    /// The store is a tab, so the post has to name a browser window: from the standalone
    /// settings window, the key window is not one. Static because the settings sidebar's
    /// Extensions link row calls it without this view ever being on screen.
    static func openStore() {
        var host: NSWindow?
        if #available(macOS 15.4, *) {
            host = ExtensionWindowAdapter.focusedAdapter()?.window
        }
        NotificationCenter.default.post(
            name: .openSettingsTab,
            object: host,
            userInfo: ["tab": SettingsTab.extensions.rawValue]
        )
    }

    private func promptForFile() {
        installError = nil
        guard let url = ExtensionManager.chooseFile() else { return }
        Task {
            do {
                try await extensionManager.installExtension(fromFile: url)
            } catch {
                installError = error.localizedDescription
            }
        }
    }
}
