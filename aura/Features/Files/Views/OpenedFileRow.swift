import AppKit
import SwiftUI

/// One file in the tray. Name on top, the exact `file://` location underneath.
///
/// The location is shown percent-encoded and selectable because it is the string people
/// paste into other tools, and a prettified path would be the wrong one when the name has
/// a space in it. Same 16pt icon slot, hover background and hover-only "…" button as
/// `DownloadHistoryRow`, so the two panels read as one.
struct OpenedFileRow: View {
    let file: OpenedFile

    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(DialogManager.self) private var dialogManager
    @EnvironmentObject private var privacyMode: PrivacyMode
    @Environment(\.theme) private var theme

    @State private var isHovered = false
    @State private var menuAnchor: NSView?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.symbolName)
                .font(.system(size: 13))
                .foregroundColor(theme.mutedForeground)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(file.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if file.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(theme.mutedForeground)
                    }
                }

                Text(file.locationString)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(file.locationString)
            }

            Spacer(minLength: 0)

            moreMenuButton
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            ConditionallyConcentricRectangle(cornerRadius: AuraRadius.row)
                .fill(isHovered ? theme.mutedBackground.opacity(0.5) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(AnimationSettings.easeOut(0.1)) { isHovered = hovering }
        }
        .onTapGesture(perform: open)
        .auraContextMenu { menuItems }
        .accessibilityLabel("\(file.displayName), \(file.locationString)")
    }

    private var moreMenuButton: some View {
        Button {
            menuAnchor?.presentAuraMenu(menuItems)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
        .background(AuraMenuAnchorView { menuAnchor = $0 })
        .fixedSize()
        .accessibilityLabel("File actions")
    }

    private var menuItems: [AuraMenuItem] {
        Array {
            AuraMenuItem.item("Open in Aura", icon: "arrow.up.doc", action: open)
            AuraMenuItem.item("Reveal in Finder", icon: "folder") {
                NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
            }
            AuraMenuItem.item("Open in Default App", icon: "arrow.up.forward.app") {
                FileAccessStore.shared.beginAccess(to: file.url)
                NSWorkspace.shared.open(file.url)
            }
            AuraMenuItem.item("Copy Path", icon: "doc.on.doc") {
                // The percent-encoded location, which is the form that survives being
                // pasted into a terminal, a chat message or another browser.
                ClipboardUtils.copyToClipboard(file.locationString)
            }
            AuraMenuItem.separator
            AuraMenuItem.item(
                file.isPinned ? "Unpin from Tray" : "Pin to Tray",
                icon: file.isPinned ? "pin.slash" : "pin"
            ) {
                withAnimation(AnimationSettings.easeOut(0.15)) {
                    OpenedFileStore.shared.setPinned(file, !file.isPinned)
                }
            }
            AuraMenuItem.item("Remove", icon: "minus.circle", isDestructive: true) {
                withAnimation(AnimationSettings.easeOut(0.15)) {
                    OpenedFileStore.shared.remove(file)
                }
            }
        }
    }

    // MARK: - Actions

    /// Reopening yesterday's file is the whole point of the tray, and yesterday's sandbox
    /// grant is gone, so a row whose stored bookmark no longer resolves asks again rather
    /// than opening a tab that cannot read anything.
    private func open() {
        let target = file.url
        guard FileAccessStore.shared.needsConsent(for: target) else {
            openTab(at: target)
            return
        }
        dialogManager.confirm(
            title: FileOpenService.consentTitle(for: target),
            message: FileOpenService.consentMessage,
            iconImage: Image(systemName: "doc.text"),
            confirmLabel: "Choose File",
            onConfirm: {
                guard let granted = FileOpenService.shared.requestAccess(to: target) else { return }
                openTab(at: granted)
            }
        )
    }

    private func openTab(at url: URL) {
        tabManager.openTab(
            url: url,
            historyManager: historyManager,
            downloadManager: downloadManager,
            focusAfterOpening: true,
            isPrivate: privacyMode.isPrivate
        )
    }
}
