import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var updateService: UpdateService
    @Bindable private var settings = SettingsStore.shared
    @State private var notices = ""

    private static let repositoryURL = URL(string: "https://github.com/Sowyu/Aura")

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

            // Both browsers this tour borrows from lose it after the first run; a
            // replay is one flag, so it gets a button.
            OraButton(label: "Show the welcome tour again", variant: .secondary, size: .sm) {
                settings.onboardingCompleted = false
            }
        }
    }

    /// One button and one status line, both driven by `UpdateService.phase`. The button
    /// checks when there is nothing to install and installs when there is, so the whole
    /// update is the same single press it is in the toolbar.
    private var updatesCard: some View {
        SettingsCard(header: "Updates") {
            Toggle("Check for updates automatically", isOn: $settings.autoUpdateEnabled)
                .onChange(of: settings.autoUpdateEnabled) { _, enabled in
                    updateService.applyAutomaticChecks(enabled)
                }

            HStack(spacing: 10) {
                Button(updateService.phase.settingsButtonTitle) {
                    updateService.installAvailableUpdate()
                }
                .disabled(updateService.phase.buttonAction == .busy)

                if updateService.phase.buttonAction == .busy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let status = updateService.phase.statusText {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
            }

            if let lastCheck = updateService.lastCheckDate {
                Text("Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
            }
        }
    }

    private var statusColor: Color {
        switch updateService.phase {
        case .available, .readyToInstall: return theme.success
        case .failed: return theme.destructive
        default: return theme.mutedForeground
        }
    }

    private var licenceCard: some View {
        SettingsCard(header: "Licence and credits") {
            Text("Aura is free software under the GNU General Public License, version 3.")
                .font(.system(size: 13))

            // The GPL keeps the origin notice; the upstream project is gone, so no link.
            Text("Aura started as a fork of the Ora browser.")
                .font(.system(size: 13))
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
