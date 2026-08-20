import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DownloadHistoryRow: View {
    let download: Download
    @EnvironmentObject var downloadManager: DownloadManager
    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var menuAnchor: NSView?

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
            }

            if isHovered {
                moreMenuButton
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            ConditionallyConcentricRectangle(cornerRadius: 12)
                .fill(isHovered ? theme.mutedBackground.opacity(0.5) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            if download.status == .completed {
                downloadManager.openFile(download)
            }
        }
        .auraContextMenu { downloadMenuItems }
    }

    // MARK: - Subviews

    private var fileIconView: some View {
        Image(nsImage: nativeFileIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 32, height: 32)
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
                    .animation(.easeOut(duration: 0.2), value: download.displayProgress)
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
        .buttonStyle(.plain)
        .background(AuraMenuAnchorView { menuAnchor = $0 })
        .fixedSize()
    }

    private var downloadMenuItems: [AuraMenuItem] {
        Array {
            if download.status == .completed {
                AuraMenuItem.item("Open", icon: "arrow.up.doc") {
                    downloadManager.openFile(download)
                }
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
                    withAnimation(.easeOut(duration: 0.15)) {
                        downloadManager.moveToTrash(download)
                    }
                }
            }
            if download.status == .downloading {
                AuraMenuItem.item("Cancel Download", icon: "xmark.circle", isDestructive: true) {
                    downloadManager.cancelDownload(download)
                }
            }
            if download.status == .failed || download.status == .cancelled {
                AuraMenuItem.item("Retry Download", icon: "arrow.clockwise") {
                    downloadManager.retryDownload(download)
                }
            }
            if download.status != .downloading {
                AuraMenuItem.separator
                AuraMenuItem.item("Remove from Aura", icon: "minus.circle") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        downloadManager.deleteDownload(download)
                    }
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var sourceHostname: String? {
        guard let url = URL(string: download.originalURLString) else { return nil }
        return url.host?.replacingOccurrences(of: "www.", with: "")
    }

    /// Returns the native macOS file icon for this download, matching what Finder shows.
    private var nativeFileIcon: NSImage {
        if let url = download.destinationURL,
           FileManager.default.fileExists(atPath: url.path)
        {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let ext = (download.fileName as NSString).pathExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private var statusColor: Color {
        switch download.status {
        case .downloading: return theme.accent
        case .failed: return .red
        case .cancelled: return .orange
        default: return .secondary
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
        default:
            return "Pending"
        }
    }

    private func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
