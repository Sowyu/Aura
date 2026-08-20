import AppKit
import SwiftUI

struct ExtensionsSettingsView: View {
    @StateObject private var extensionManager = ExtensionManager.shared
    @State private var installError: String?

    var body: some View {
        SettingsSection {
            if !ExtensionManager.isSupported {
                SettingsCard {
                    Label(
                        "Extensions require macOS 15.4 or later.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundColor(.secondary)
                }
            } else {
                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Installed Extensions")
                                .font(.headline)
                            Text("Extensions are granted every permission they request and run in normal windows only.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Install Extension…") {
                            promptForExtensionFolder()
                        }
                    }

                    if let installError {
                        Text(installError)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                if extensionManager.installedExtensions.isEmpty {
                    SettingsCard {
                        Text("No extensions installed. Choose an unpacked extension folder containing a manifest.json.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    SettingsCard {
                        VStack(spacing: 0) {
                            ForEach(extensionManager.installedExtensions) { item in
                                ExtensionRow(item: item)
                                if item.id != extensionManager.installedExtensions.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if ExtensionManager.isSupported {
                extensionManager.start()
            }
        }
    }

    private func promptForExtensionFolder() {
        installError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an unpacked extension folder (it must contain manifest.json)."
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ExtensionManager.shared.installExtension(from: url)
        } catch {
            installError = error.localizedDescription
        }
    }
}

private struct ExtensionRow: View {
    let item: InstalledExtension

    var body: some View {
        HStack(spacing: 12) {
            if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .frame(width: 24, height: 24)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                    if let version = item.displayVersion {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if let loadError = item.loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { item.isEnabled },
                set: { ExtensionManager.shared.setEnabled($0, for: item.id) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Button {
                ExtensionManager.shared.removeExtension(item.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Remove extension")
        }
        .padding(.vertical, 8)
    }
}
