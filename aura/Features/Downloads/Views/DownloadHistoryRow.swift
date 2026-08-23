import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadHistoryRow: View {
    let download: Download
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(TabManager.self) private var tabManager
    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var menuAnchor: NSView?
    /// Resolved once the row appears, not per redraw: answering it reads an extended
    /// attribute off the disk, and the row redraws with every progress tick around it.
    @State private var openAction: DownloadOpenAction?

    var body: some View {
        HStack(spacing: 10) {
            fileIconView

            VStack(alignment: .leading, spacing: 2) {
                Text(download.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    if let hostname = sourceHostname {
                        Text(hostname)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if !statusText.isEmpty {
                            Text("\u{00B7}")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .layoutPriority(1)
                        }
                    }

                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundColor(statusColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    if download.status == .completed {
                        Text(download.formattedFileSize)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }

                if download.status == .downloading {
                    progressBar
                }

                if let hint = quarantineHint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundColor(theme.warning)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Always laid out, so hovering toggles opacity only: the file name never shifts.
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
            withAnimation(AnimationSettings.easeOut(0.1)) {
                isHovered = hovering
            }
        }
        .onTapGesture(perform: activate)
        .auraContextMenu { downloadMenuItems }
        .onAppear(perform: resolveOpenAction)
        .onChange(of: download.status) { _, _ in resolveOpenAction() }
    }

    // MARK: - Subviews

    /// The same 16pt slot a history row gives a favicon, so the two panels line up.
    private var fileIconView: some View {
        Image(systemName: fileSymbol)
            .font(.system(size: 13))
            .foregroundColor(theme.mutedForeground)
            .frame(width: 16, height: 16)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.mutedBackground)
                    .frame(height: 3)

                Capsule()
                    .fill(theme.accent)
                    .frame(width: geo.size.width * download.displayProgress, height: 3)
                    .animation(AnimationSettings.easeOut(0.15), value: download.displayProgress)
            }
        }
        .frame(height: 3)
        .padding(.top, 2)
    }

    private var moreMenuButton: some View {
        Button {
            menuAnchor?.presentAuraMenu(downloadMenuItems)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
        .background(AuraMenuAnchorView { menuAnchor = $0 })
        .fixedSize()
    }

    private var downloadMenuItems: [AuraMenuItem] {
        Array {
            if download.status == .completed {
                AuraMenuItem.item("Open", icon: "arrow.up.doc", action: activate)
                AuraMenuItem.item("Show in Finder", icon: "folder") {
                    downloadManager.openDownloadInFinder(download)
                }
                AuraMenuItem.item("Copy Path", icon: "doc.on.doc") {
                    if let path = download.destinationURL?.path {
                        ClipboardUtils.copyToClipboard(path)
                    }
                }
                AuraMenuItem.separator
                AuraMenuItem.item("Move to Trash", icon: "trash", isDestructive: true) {
                    withAnimation(AnimationSettings.easeOut(0.15)) {
                        downloadManager.moveToTrash(download)
                    }
                }
            }
            if isInFlight {
                AuraMenuItem.item("Cancel Download", icon: "xmark.circle", isDestructive: true) {
                    downloadManager.cancelDownload(download)
                }
            }
            if download.status == .failed || download.status == .cancelled {
                switch retryAction {
                case .resume:
                    AuraMenuItem.item("Resume Download", icon: "play.circle") {
                        downloadManager.resumeDownload(download, using: tabManager.activeTab?.browserPage)
                    }
                case .retry:
                    AuraMenuItem.item("Retry Download", icon: "arrow.clockwise") {
                        downloadManager.retryDownload(download)
                    }
                }
            }
            if !isInFlight {
                AuraMenuItem.separator
                AuraMenuItem.item("Remove from Aura", icon: "minus.circle") {
                    withAnimation(AnimationSettings.easeOut(0.15)) {
                        downloadManager.deleteDownload(download)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    /// Clicking the row, and the Open menu item, answer to the same rule the auto-open
    /// after a finished download uses. An archive Aura would not open for you is not one
    /// it opens because you clicked it.
    private func activate() {
        guard download.status == .completed else { return }
        switch openAction ?? .open {
        case .open:
            downloadManager.openFile(download)
        case let .reveal(reason):
            downloadManager.revealDownload(download, explaining: reason)
        }
    }

    private func resolveOpenAction() {
        guard download.status == .completed, let url = download.destinationURL else {
            openAction = nil
            return
        }
        openAction = DownloadManager.openAction(
            fileExtension: url.pathExtension,
            isQuarantined: DownloadManager.isQuarantined(url)
        )
    }

    // MARK: - Computed Properties

    /// Downloading and waiting for a slot are both "in flight": the row offers Cancel
    /// and withholds Remove for either.
    private var isInFlight: Bool {
        download.status == .downloading || download.status == .pending
    }

    private var retryAction: DownloadRetryAction {
        DownloadManager.retryAction(
            hasResumeData: downloadManager.canResume(download),
            hasPage: tabManager.activeTab?.browserPage != nil,
            hasDestination: download.destinationURL != nil
        )
    }

    /// Only shown where it changes what the reader should do: a stamped installer or
    /// archive is the case where Finder is the way through Gatekeeper. A stamped PDF
    /// opens on its own and needs no advice.
    private var quarantineHint: String? {
        guard case let .reveal(reason) = openAction, reason == .quarantined else { return nil }
        return reason.explanation
    }

    /// Only the leading `www.` comes off. Replacing every occurrence turned hosts like
    /// `newww.example.com` into `neexample.com`.
    private var sourceHostname: String? {
        guard let host = URL(string: download.originalURLString)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A symbol for the file's broad kind. Finder's own icon is a full-colour 32pt asset
    /// and reads as a foreign object next to the panel's flat 16pt glyphs.
    private var fileSymbol: String {
        let ext = (download.fileName as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .application) { return "app" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    private var statusColor: Color {
        switch download.status {
        case .downloading: return theme.accent
        case .failed: return theme.destructive
        case .cancelled: return theme.warning
        default: return theme.mutedForeground
        }
    }

    private var statusText: String {
        switch download.status {
        case .downloading:
            if download.displayFileSize > 0 {
                let pct = Int(download.displayProgress * 100)
                return "\(download.formattedDownloadedSize) of \(download.formattedFileSize) \u{00B7} \(pct)%"
            }
            return download.formattedDownloadedSize
        case .completed:
            return timeAgo(from: download.completedAt ?? download.createdAt)
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .pending:
            // No progress bar for these: a bar stuck at zero reads as broken rather
            // than as a download that has not been given a slot yet.
            return "Waiting"
        }
    }

    private func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
