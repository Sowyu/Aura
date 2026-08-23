import SwiftUI

/// The file tray button, next to `DownloadsWidget` at the foot of the sidebar. Same 28pt
/// slot, same flat hover, same badge rule: a count only from two files up, because one is
/// what the panel says anyway.
struct FilesWidget: View {
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(\.theme) private var theme

    private var files: [OpenedFile] {
        OpenedFileStore.shared.entries
    }

    var body: some View {
        Button {
            withAnimation(AnimationSettings.easeOut(0.15)) {
                sidebarManager.togglePanel(.files)
            }
        } label: {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.mutedForeground)
                .frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) { countBadge }
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button, tint: theme.invertedSolidWindowBackgroundColor))
        .help(helpText)
        .accessibilityLabel("Files")
        // The tray reads itself off disk once, here rather than in a body: the widget is
        // always on screen in a normal window, so it is the earliest safe place.
        .task { OpenedFileStore.shared.loadIfNeeded() }
    }

    @ViewBuilder
    private var countBadge: some View {
        if files.count > 1 {
            Text("\(files.count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(theme.solidWindowBackgroundColor)
                .frame(width: 13, height: 13)
                .background(Circle().fill(theme.accent))
                .offset(x: 2, y: -2)
        }
    }

    private var helpText: String {
        files.isEmpty ? "Files" : "Files (\(files.count))"
    }
}
