import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// `aura://extensions`: the add-on store, rendered natively inside a tab like
/// `aura://settings`. Installed extensions sit on top, browsing below.
struct ExtensionStoreView: View {
    @Environment(\.theme) private var theme
    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @EnvironmentObject private var privacyMode: PrivacyMode

    @State private var model = ExtensionStoreModel()
    @State private var query = ""
    @State private var fileError: String?

    private let extensionManager = ExtensionManager.shared

    private static let columnWidth: CGFloat = 960
    private static let padding: CGFloat = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if ExtensionManager.isSupported {
                    installedSection
                    browseSection
                } else {
                    SettingsCard {
                        Label("Extensions require macOS 15.4 or later.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .padding(Self.padding)
            .frame(maxWidth: .infinity)
        }
        .background(theme.background.opacity(0.85))
        .onAppear {
            guard ExtensionManager.isSupported else { return }
            extensionManager.start()
            model.loadIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extensions")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Firefox add-ons install straight from addons.mozilla.org, "
                        + "because they are standard web extensions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Install from file…", action: promptForFile)
                    .controlSize(.regular)
                    .fixedSize()
            }

            if let fileError {
                Text(fileError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            searchField
            filters
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search add-ons, or paste an addons.mozilla.org link", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { model.search(query) }
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .onChange(of: query) { _, newValue in
            model.scheduleSearch(newValue)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ExtensionStoreChip(title: "All", isSelected: model.type == nil) {
                    model.select(type: nil)
                }
                ForEach(FirefoxAddonType.allCases) { type in
                    ExtensionStoreChip(title: type.pluralTitle, isSelected: model.type == type) {
                        model.select(type: type)
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Sort")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(FirefoxAddonSort.allCases) { sort in
                    ExtensionStoreChip(title: sort.title, isSelected: model.sort == sort) {
                        model.select(sort: sort)
                    }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var installedSection: some View {
        if !extensionManager.installedExtensions.isEmpty {
            SettingsCard(header: "Your extensions") {
                VStack(spacing: 0) {
                    ForEach(extensionManager.installedExtensions) { item in
                        InstalledExtensionRow(
                            item: item,
                            optionsURL: extensionManager.optionsPageURL(for: item.id),
                            openOptions: openInNewTab
                        )
                        if item.id != extensionManager.installedExtensions.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.messageIsError ? Color.red : Color.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12)], spacing: 12) {
                ForEach(model.addons) { addon in
                    ExtensionStoreCard(
                        addon: addon,
                        isInstalling: model.installingSlugs.contains(addon.slug),
                        install: { model.install(addon) }
                    )
                }
            }

            if model.isLoading, model.addons.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }

            if model.hasMore {
                Button(model.isLoadingMore ? "Loading…" : "Load more") { model.loadMore() }
                    .controlSize(.regular)
                    .disabled(model.isLoadingMore)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Actions

    private func openInNewTab(_ url: URL) {
        tabManager.openTab(
            url: url,
            historyManager: historyManager,
            downloadManager: downloadManager,
            isPrivate: privacyMode.isPrivate
        )
    }

    /// A folder with manifest.json, or a packaged extension. `.crx` included: it is a
    /// zip behind a signature header, which the installer strips.
    private func promptForFile() {
        fileError = nil
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
            fileError = error.localizedDescription
        }
    }
}
