import AppKit
import SwiftUI

struct ExtensionsSettingsView: View {
    private let extensionManager = ExtensionManager.shared
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
                        .controlSize(.regular)
                        .fixedSize()
                    }

                    if let installError {
                        Text(installError)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                FirefoxAddonSearchCard()

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

private struct FirefoxAddonSearchCard: View {
    @State private var query = ""
    @State private var results: [FirefoxAddon] = []
    @State private var isSearching = false
    @State private var installingSlugs: Set<String> = []
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        SettingsCard(header: "Firefox Add-ons") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Search addons.mozilla.org, or paste an add-on page URL. "
                        + "Firefox extensions are standard web extensions and install directly."
                )
                .font(.caption)
                .foregroundColor(.secondary)

                HStack {
                    TextField("Search add-ons or paste an addons.mozilla.org URL", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { runSearch() }
                    Button("Search") { runSearch() }
                        .controlSize(.regular)
                        .fixedSize()
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(statusIsError ? .red : .secondary)
                }

                ForEach(results) { addon in
                    FirefoxAddonResultRow(
                        addon: addon,
                        isInstalling: installingSlugs.contains(addon.slug),
                        install: { install(addon) }
                    )
                    if addon.id != results.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        statusMessage = nil
        statusIsError = false
        isSearching = true
        results = []
        Task { @MainActor in
            defer { isSearching = false }
            do {
                if let slug = FirefoxAddonStore.slug(fromPageURL: text) {
                    results = try await [FirefoxAddonStore.shared.addon(slug: slug)]
                } else {
                    results = try await FirefoxAddonStore.shared.search(text)
                    if results.isEmpty {
                        statusMessage = "No add-ons found for \"\(text)\"."
                    }
                }
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
    }

    private func install(_ addon: FirefoxAddon) {
        statusMessage = nil
        statusIsError = false
        installingSlugs.insert(addon.slug)
        Task { @MainActor in
            defer { installingSlugs.remove(addon.slug) }
            do {
                try await ExtensionManager.shared.installFirefoxAddon(addon)
                statusMessage = "Installed \(addon.name)."
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
    }
}

private struct FirefoxAddonResultRow: View {
    let addon: FirefoxAddon
    let isInstalling: Bool
    let install: () -> Void

    private var formattedUsers: String {
        addon.dailyUsers >= 1000 ? "\(addon.dailyUsers / 1000)k users" : "\(addon.dailyUsers) users"
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: addon.iconURL) { image in
                image.resizable()
            } placeholder: {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundColor(.secondary)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(addon.name)
                    if let version = addon.version {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(formattedUsers)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let summary = addon.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Install", action: install)
                    .controlSize(.regular)
                    .fixedSize()
            }
        }
        .padding(.vertical, 6)
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
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.interactive(cornerRadius: 5))
            .foregroundColor(.secondary)
            .help("Remove extension")
        }
        .padding(.vertical, 8)
    }
}
