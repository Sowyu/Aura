import SwiftUI

/// The downloads button, drawn once and used twice: in the top toolbar and at the foot
/// of the sidebar. Both are 28pt, so the progress badge has to say "three files, 40
/// percent, two minutes left" inside a ring, a count and a tooltip.
struct DownloadsWidget: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(\.theme) private var theme

    private var activeDownloads: [Download] {
        downloadManager.activeDownloads
    }

    /// Byte-weighted across everything in flight, so the ring tracks the bytes left
    /// rather than the mean of the per-file fractions.
    private var totalProgress: Double {
        DownloadManager.aggregateProgress(of: activeDownloads)
    }

    private var hasActiveDownloads: Bool {
        !activeDownloads.isEmpty
    }

    var body: some View {
        Button {
            withAnimation(AnimationSettings.easeOut(0.15)) {
                sidebarManager.togglePanel(.downloads)
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
                        .animation(AnimationSettings.easeOut(0.15), value: totalProgress)
                }

                if hasActiveDownloads {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(theme.accent)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.mutedForeground)
                }
            }
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) { countBadge }
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button, tint: theme.invertedSolidWindowBackgroundColor))
        .help(helpText)
        .accessibilityLabel(Text("Downloads"))
        .accessibilityValue(Text(helpText))
    }

    /// Only from two files up. One download is what the ring already says, and a badge
    /// reading "1" is noise on a 28pt button.
    @ViewBuilder
    private var countBadge: some View {
        if activeDownloads.count > 1 {
            Text("\(activeDownloads.count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(theme.solidWindowBackgroundColor)
                .frame(width: 13, height: 13)
                .background(Circle().fill(theme.accent))
                .offset(x: 2, y: -2)
        }
    }

    /// Where the speed and the ETA actually fit. The number itself is smoothed in
    /// `DownloadManager`, so this string only changes about once a second.
    private var helpText: String {
        guard hasActiveDownloads else { return "Downloads" }
        let summary = downloadManager.throughput.summary
        guard !summary.isEmpty else { return "Downloads (\(activeDownloads.count))" }
        return "Downloads \u{00B7} \(summary)"
    }
}
