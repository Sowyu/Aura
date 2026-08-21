import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings keeps only a pointer: browsing, installing and per-extension controls all
/// live on the `aura://extensions` page, which has room for them.
struct ExtensionsSettingsView: View {
    private let extensionManager = ExtensionManager.shared
    @State private var installError: String?

    private var installedCount: Int {
        extensionManager.installedExtensions.count
    }

    private var summary: String {
        guard ExtensionManager.isSupported else {
            return "Extensions require macOS 15.4 or later."
        }
        switch installedCount {
        case 0: return "No extensions installed yet."
        case 1: return "1 extension installed."
        default: return "\(installedCount) extensions installed."
        }
    }

    var body: some View {
        SettingsSection {
            SettingsCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extensions")
                            .font(.headline)
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Open Extension Store", action: openStore)
                            .controlSize(.regular)
                            .fixedSize()
                            .disabled(!ExtensionManager.isSupported)
                        Button("Install from file…", action: promptForFile)
                            .controlSize(.regular)
                            .fixedSize()
                            .disabled(!ExtensionManager.isSupported)
                    }
                }

                if let installError {
                    Text(installError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear {
            if ExtensionManager.isSupported {
                extensionManager.start()
            }
        }
    }

    /// The store is a tab, so the post has to name a browser window: from the standalone
    /// settings window, the key window is not one.
    private func openStore() {
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.zip]
            + ["xpi", "crx"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose an unpacked extension folder, or an .xpi, .zip, or .crx file."
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try extensionManager.installExtension(fromFile: url)
        } catch {
            installError = error.localizedDescription
        }
    }
}
