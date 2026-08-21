import AppKit
import SwiftUI

/// One AMO listing. Compatibility is decided from the record, before any download.
struct ExtensionStoreCard: View {
    let addon: FirefoxAddon
    let isInstalling: Bool
    let install: () -> Void

    private let extensionManager = ExtensionManager.shared

    private var compatibility: ExtensionCompatibility {
        .evaluate(addon)
    }

    private var installed: InstalledExtension? {
        extensionManager.installedExtension(matching: addon)
    }

    var body: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 4) {
                    titleRow
                    byline
                    Text(addon.summary ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                    footer
                }
            }
        }
    }

    private var icon: some View {
        AsyncImage(url: addon.iconURL) { image in
            image.resizable()
        } placeholder: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(addon.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            ExtensionCompatibilityBadge(compatibility: compatibility)
        }
    }

    private var byline: some View {
        HStack(spacing: 6) {
            if let authorLine = addon.authorLine {
                Text(authorLine)
                    .lineLimit(1)
            }
            if let version = addon.version {
                Text("v\(version)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if addon.averageRating > 0 {
                Label(String(format: "%.1f", addon.averageRating), systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
            }
            Text(ExtensionStoreFormat.userCount(addon.dailyUsers))
            Spacer(minLength: 8)
            installControl
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var installControl: some View {
        if let installed {
            HStack(spacing: 6) {
                Text("Installed")
                    .font(.caption.weight(.medium))
                Toggle("", isOn: Binding(
                    get: { installed.isEnabled },
                    set: { extensionManager.setEnabled($0, for: installed.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(installed.isEnabled ? "Disable" : "Enable")
                ExtensionRemoveButton(id: installed.id)
            }
        } else if isInstalling {
            ProgressView()
                .controlSize(.small)
        } else if compatibility.allowsInstall {
            Button("Install", action: install)
                .controlSize(.small)
                .fixedSize()
        } else {
            Button("Install") {}
                .controlSize(.small)
                .fixedSize()
                .disabled(true)
                .help(compatibility.detail ?? "This add-on can't run under WebKit.")
        }
    }
}

/// Green / amber / red verdict. The tooltip names what is missing.
struct ExtensionCompatibilityBadge: View {
    let compatibility: ExtensionCompatibility

    private var color: Color {
        switch compatibility {
        case .supported: return .green
        case .partial: return .orange
        case .notSupported: return .red
        }
    }

    var body: some View {
        Text(compatibility.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .fixedSize()
            .help(compatibility.detail ?? "Nothing this add-on asks for is missing under WebKit.")
    }
}

/// One installed extension in the "Your extensions" card.
struct InstalledExtensionRow: View {
    let item: InstalledExtension
    let optionsURL: URL?
    let openOptions: (URL) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                    if let version = item.displayVersion {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let loadError = item.loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if let optionsURL {
                Button("Open options") { openOptions(optionsURL) }
                    .controlSize(.small)
                    .fixedSize()
            }

            Toggle("", isOn: Binding(
                get: { item.isEnabled },
                set: { ExtensionManager.shared.setEnabled($0, for: item.id) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            ExtensionRemoveButton(id: item.id)
        }
        .padding(.vertical, 8)
    }
}

struct ExtensionRemoveButton: View {
    let id: String

    var body: some View {
        Button {
            ExtensionManager.shared.removeExtension(id)
        } label: {
            Image(systemName: "trash")
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.interactive(cornerRadius: 5))
        .foregroundStyle(.secondary)
        .help("Remove extension")
    }
}

/// Filter and sort pill. Flat: the fill changes, nothing moves.
struct ExtensionStoreChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                .background(fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var fill: Color {
        if isSelected {
            return theme.accent.opacity(isHovering ? 0.85 : 1)
        }
        return Color.primary.opacity(isHovering ? 0.12 : 0.06)
    }
}

enum ExtensionStoreFormat {
    /// AMO's average daily users, short enough to sit in a card footer.
    static func userCount(_ users: Int) -> String {
        switch users {
        case 1_000_000...:
            return String(format: "%.1fM users", Double(users) / 1_000_000)
        case 1000...:
            return "\(users / 1000)k users"
        default:
            return "\(users) users"
        }
    }
}
