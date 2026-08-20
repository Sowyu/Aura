import SwiftUI

struct DownloadsWidget: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @Environment(\.theme) private var theme

    /// Aggregate progress across all active downloads (0...1)
    private var totalProgress: Double {
        let active = downloadManager.activeDownloads
        guard !active.isEmpty else { return 0 }
        let total = active.reduce(0.0) { $0 + $1.displayProgress }
        return total / Double(active.count)
    }

    private var hasActiveDownloads: Bool {
        !downloadManager.activeDownloads.isEmpty
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                downloadManager.isShowingDownloadsHistory.toggle()
            }
        } label: {
            ZStack {
                // Circular progress ring behind the icon when downloading
                if hasActiveDownloads {
                    Circle()
                        .stroke(theme.accent.opacity(0.2), lineWidth: 2)
                        .frame(width: 24, height: 24)

                    Circle()
                        .trim(from: 0, to: totalProgress)
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.15), value: totalProgress)
                }

                if hasActiveDownloads {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(theme.accent)
                } else {
                    OraIcons(icon: .downloadBox, size: .md, color: .secondary)
                }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.interactive(cornerRadius: 8, tint: theme.invertedSolidWindowBackgroundColor))
    }
}
