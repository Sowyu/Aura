import AppKit
import SwiftUI

struct AboutSettingsView: View {
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
                        .font(.title2.weight(.semibold))
                    Text(versionString)
                        .foregroundStyle(.secondary)
                    Text("Fast, secure, and beautiful browser built for macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let result = updateService.lastCheckResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(updateService.updateAvailable ? .green : .secondary)
            }

            if let lastCheck = updateService.lastCheckDate {
                Text("Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var licenceCard: some View {
        SettingsCard(header: "Licence and credits") {
            Text("Aura is free software under the GNU General Public License, version 3.")
                .font(.callout)

            HStack(spacing: 6) {
                Text("Forked from the Ora browser.")
                    .font(.callout)
                if let url = Self.oraURL {
                    Link("the-ora/browser", destination: url)
                        .font(.callout)
                }
            }
        }
    }

    private var noticesCard: some View {
        SettingsCard(header: "Third-party notices") {
            ScrollView {
                Text(notices.isEmpty ? "THIRD_PARTY_NOTICES.md is not in this build." : notices)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
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
