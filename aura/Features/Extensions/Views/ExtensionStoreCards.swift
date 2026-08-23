import AppKit
import SwiftUI

/// One AMO listing. Compatibility is decided from the record, before any download.
struct ExtensionStoreCard: View {
    @Environment(\.theme) private var theme
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
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
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
                .foregroundStyle(theme.mutedForeground)
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous))
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
        .font(.system(size: 11))
        .foregroundStyle(theme.mutedForeground)
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
        .font(.system(size: 11))
        .foregroundStyle(theme.mutedForeground)
    }

    @ViewBuilder
    private var installControl: some View {
        if let installed {
            HStack(spacing: 6) {
                Text("Installed")
                    .font(.system(size: 11, weight: .medium))
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

/// Green / amber / red verdict. The tooltip names what is missing. The verdict is the
/// text colour; the chip stays the same flat muted fill either way.
struct ExtensionCompatibilityBadge: View {
    @Environment(\.theme) private var theme
    let compatibility: ExtensionCompatibility

    private var color: Color {
        switch compatibility {
        case .supported: return theme.success
        case .partial: return theme.warning
        case .notSupported: return theme.destructive
        }
    }

    var body: some View {
        Text(compatibility.title)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                theme.mutedBackground,
                in: .rect(cornerRadius: AuraRadius.button, style: .continuous)
            )
            .foregroundStyle(color)
            .fixedSize()
            .help(compatibility.detail ?? "Nothing this add-on asks for is missing under WebKit.")
    }
}

/// One installed extension in the "Your extensions" card.
struct InstalledExtensionRow: View {
    @Environment(\.theme) private var theme
    let item: InstalledExtension
    let optionsURL: URL?
    let openOptions: (URL) -> Void

    @State private var updateError: String?

    private var manager: ExtensionManager { ExtensionManager.shared }

    var body: some View {
        HStack(spacing: 12) {
            if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(theme.mutedForeground)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                    if let version = item.displayVersion {
                        Text("v\(version)")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
                if let loadError = item.loadError {
                    Text(loadError)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.warning)
                        .lineLimit(2)
                }
                if let updateError {
                    Text(updateError)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.destructive)
                        .lineLimit(2)
                }
                privateWindowsToggle
            }

            Spacer(minLength: 8)

            updateControl

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

    /// The AMO version check found something newer. Updating re-downloads the add-on
    /// over the same folder, so nothing it stored is lost; a permission it did not ask
    /// for before brings the consent sheet back by itself.
    @ViewBuilder
    private var updateControl: some View {
        if manager.updatingIDs.contains(item.id) {
            ProgressView()
                .controlSize(.small)
        } else if let version = manager.availableUpdate(for: item.id) {
            Button("Update to \(version)") {
                updateError = nil
                Task {
                    do {
                        try await manager.updateExtension(item.id)
                    } catch {
                        updateError = error.localizedDescription
                    }
                }
            }
            .controlSize(.small)
            .fixedSize()
            .help("Version \(version) is on addons.mozilla.org.")
        }
    }

    /// Firefox's private-browsing switch. Off by default, and the tooltip says what
    /// turning it on actually hands over, because "allow in private windows" reads like
    /// a display option rather than a data grant.
    private var privateWindowsToggle: some View {
        Toggle(isOn: Binding(
            get: { ExtensionManager.shared.runsInPrivateWindows(item.id) },
            set: { ExtensionManager.shared.setRunsInPrivateWindows($0, for: item.id) }
        )) {
            Text("Run in private windows")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help("Lets this extension see the tabs, cookies and requests of private windows.")
    }
}

struct ExtensionRemoveButton: View {
    @Environment(\.theme) private var theme
    let id: String

    var body: some View {
        Button {
            ExtensionManager.shared.removeExtension(id)
        } label: {
            Image(systemName: "trash")
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
        .foregroundStyle(theme.mutedForeground)
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
                .foregroundStyle(isSelected ? theme.accent : theme.foreground)
                .background(fill, in: .rect(cornerRadius: AuraRadius.button, style: .continuous))
                .contentShape(.rect(cornerRadius: AuraRadius.button))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(AnimationSettings.easeOut(0.12), value: isSelected)
        .animation(AnimationSettings.easeOut(0.12), value: isHovering)
    }

    /// Selection is carried by the accent text colour, so the fill only has to say
    /// "this one is on" and hover only has to say "the pointer is here".
    private var fill: Color {
        if isSelected {
            return theme.accent.opacity(isHovering ? 0.24 : 0.18)
        }
        return theme.mutedBackground.opacity(isHovering ? 1 : 0.6)
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

// MARK: - Install consent

/// The sheet that stands between an extension's files landing in the profile and
/// WebKit granting it everything its manifest asks for. Flat, like every other Aura
/// dialog: one surface, one border, no elevation games.
struct ExtensionConsentSheet: View {
    @Environment(\.theme) private var theme
    let request: ExtensionConsentRequest
    let install: (Bool) -> Void
    let cancel: () -> Void

    /// Off, like Firefox: agreeing to an extension is not agreeing to hand it the
    /// browsing the user opened a private window to keep separate.
    @State private var allowsPrivateWindows = false

    /// Tall enough for the eight or so lines a normal extension asks for; anything
    /// longer scrolls rather than pushing the buttons off screen.
    private static let listHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            description
            permissionList
            privateWindowsToggle
            if let note = request.compatibility.detail {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .frame(width: 380)
        .padding(12)
        .background(theme.popoverMutedBackground)
        .cornerRadius(AuraRadius.row)
        .overlay {
            ConditionallyConcentricRectangle(cornerRadius: AuraRadius.row)
                .stroke(theme.border, lineWidth: 1)
        }
        .padding(3)
        .background(theme.popoverBackground)
        .cornerRadius(AuraRadius.pane)
        .auraFloatingShadow()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Install \(request.displayName)?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.foreground)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        let version = request.version.map { "Version \($0)" }
        return [version, request.source.label].compactMap { $0 }.joined(separator: " · ")
    }

    /// The add-on's own words about itself, translated. Two lines: it is context for
    /// the permission list below, not the thing being agreed to.
    @ViewBuilder
    private var description: some View {
        if let text = request.displayDescription, !text.isEmpty {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var permissionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.permissionLines.isEmpty
                ? "It asks for no special access."
                : "It will be able to:")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)

            if !request.permissionLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(request.permissionLines, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(theme.mutedForeground)
                                    .frame(width: 3, height: 3)
                                Text(line)
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.foreground)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Self.listHeight)
            }
        }
    }

    private var privateWindowsToggle: some View {
        Toggle(isOn: $allowsPrivateWindows) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run in private windows")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.foreground)
                Text("It sees private tabs, cookies and requests as well. Changeable later.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var buttons: some View {
        HStack {
            OraButton(label: "Cancel", variant: .secondary, keyboardShortcut: "esc", action: cancel)
            Spacer()
            OraButton(label: "Install", keyboardShortcut: "return", action: { install(allowsPrivateWindows) })
        }
    }
}

extension View {
    /// Puts pending install consent on screen. The gate itself lives in
    /// `ExtensionManager`, but the dialog stack belongs to a window, so each surface
    /// that can start an install opts in.
    func extensionConsentPrompt() -> some View {
        modifier(ExtensionConsentPrompt())
    }
}

private struct ExtensionConsentPrompt: ViewModifier {
    @Environment(DialogManager.self) private var dialogManager

    private var manager: ExtensionManager { ExtensionManager.shared }

    func body(content: Content) -> some View {
        content
            .onAppear(perform: present)
            .onChange(of: manager.pendingConsent.first?.id) { _, _ in present() }
    }

    private func present() {
        guard let request = manager.pendingConsent.first,
              manager.claimConsentPresentation(request.id)
        else { return }

        dialogManager.show { id in
            ExtensionConsentSheet(
                request: request,
                install: { allowsPrivateWindows in
                    manager.approveConsent(request, allowsPrivateWindows: allowsPrivateWindows)
                    dialogManager.dismiss(id: id)
                },
                cancel: {
                    manager.declineConsent(request)
                    dialogManager.dismiss(id: id)
                }
            )
            // Tapping the backdrop is not consent. Without this the request would stay
            // pending with nothing on screen to answer it.
            .onDisappear {
                manager.releaseConsentPresentation(request.id)
                if manager.pendingConsent.contains(where: { $0.id == request.id }) {
                    manager.declineConsent(request)
                }
            }
        }
    }
}
