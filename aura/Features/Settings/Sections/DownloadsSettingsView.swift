import AppKit
import SwiftUI

/// Where downloaded files go and what happens once they arrive.
struct DownloadsSettingsView: View {
    @Bindable private var settings = SettingsStore.shared
    @State private var folderPath = ""

    var body: some View {
        SettingsSection {
            SettingsCard(header: "Save files to") {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(folderPath.isEmpty ? defaultFolderPath : folderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                    if settings.downloadFolderBookmark != nil {
                        Button("Reset") {
                            settings.setDownloadFolder(nil)
                            folderPath = ""
                        }
                    }
                }
                .disabled(settings.askWhereToSaveDownloads)
                .opacity(settings.askWhereToSaveDownloads ? 0.5 : 1)

                Toggle("Ask where to save each file", isOn: $settings.askWhereToSaveDownloads)
            }

            SettingsCard(
                header: "After downloading",
                description: "Only documents, images, audio and video count as safe. "
                    + "Archives, disk images and apps are never opened for you."
            ) {
                Toggle("Open safe files after download", isOn: $settings.openSafeDownloads)
            }
        }
        .onAppear { folderPath = settings.resolvedDownloadFolder()?.path ?? "" }
    }

    private var defaultFolderPath: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~/Downloads"
    }

    /// The panel grants sandbox access to whatever the user picks; the bookmark on
    /// `SettingsStore` is what keeps that access across launches.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.resolvedDownloadFolder()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            settings.setDownloadFolder(url)
            folderPath = url.path
        }
    }
}
