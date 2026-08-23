import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var updateService: UpdateService
    @Bindable private var settings = SettingsStore.shared
    @State private var notices = ""

    private static let repositoryURL = URL(string: "https://github.com/Sowyu/Aura")
    private static let oraURL = URL(string: "https://github.com/the-ora/browser")

    var body: some View {
        SettingsSection {
            identityCard
            updatesCard
            licenceCard
            noticesCard
        }
        .onAppear(perform: loadNotices)
    }

    private var identityCard: some View {
        SettingsCard {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Aura")
                        .font(.system(size: 15, weight: .semibold))
                    Text(versionString)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
                }

                Spacer()
            }

            if let url = Self.repositoryURL {
                Link("Aura on GitHub", destination: url)
            }
        }
    }

    private var updatesCard: some View {
        SettingsCard(header: "Updates") {
            Toggle("Check for updates automatically", isOn: $settings.autoUpdateEnabled)

            HStack(spacing: 10) {
                Button("Check for Updates") { updateService.checkForUpdates() }

                if updateService.isCheckingForUpdates {
                    ProgressView()
                        .controlSize(.small)
                }

                if updateService.updateAvailable {
                    Text("Update available")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.success)
                }
            }

            if let result = updateService.lastCheckResult {
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(updateService.updateAvailable ? theme.success : theme.mutedForeground)
            }

            if let lastCheck = updateService.lastCheckDate {
                Text("Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
            }
        }
    }

    private var licenceCard: some View {
        SettingsCard(header: "Licence and credits") {
            Text("Aura is free software under the GNU General Public License, version 3.")
                .font(.system(size: 13))

            HStack(spacing: 6) {
                Text("Forked from the Ora browser.")
                    .font(.system(size: 13))
                if let url = Self.oraURL {
                    Link("the-ora/browser", destination: url)
                        .font(.system(size: 13))
                }
            }
        }
    }

    /// Only drawn when the file is in the bundle. The fixed 220 pt scroll view used to
    /// stay on screen either way, so a build without the notices showed a one-line error
    /// floating in an otherwise empty box.
    @ViewBuilder
    private var noticesCard: some View {
        if notices.isEmpty {
            EmptyView()
        } else {
            SettingsCard(header: "Third-party notices") {
                ScrollView {
                    Text(notices)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }

    private func loadNotices() {
        guard notices.isEmpty,
              let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        notices = text
    }
}
