import AppKit
import SwiftUI

/// The file tray: every local file Aura has opened, newest first, pinned rows on top.
///
/// Laid out as the downloads panel is, down to the 38pt header and the "Spaces" footer,
/// because it sits in the same slot and swaps with it.
struct FilesPanelView: View {
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(AppState.self) private var appState
    @Environment(ToolbarManager.self) private var toolbarManager
    @Environment(\.theme) private var theme

    @State private var isClearHovered = false

    private var files: [OpenedFile] {
        OpenedFileStore.shared.entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 4)
        .background(theme.chromeBackground)
        .background(BlurEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
        .task { OpenedFileStore.shared.loadIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        SidebarPanelHeader(title: "Files") {
            if files.contains(where: { !$0.isPinned }) {
                Button {
                    withAnimation(AnimationSettings.easeOut(0.15)) {
                        OpenedFileStore.shared.clearUnpinned()
                    }
                } label: {
                    HStack(spacing: 4) {
                        OraIcons(icon: .brush1, size: .sm, color: isClearHovered ? theme.foreground : .secondary)
                        Text("Clear").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(isClearHovered ? theme.foreground : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
                .onHover { isClearHovered = $0 }
                .help("Remove every file that is not pinned")
            }
        }
    }

    // MARK: - Footer

    private var footer: some View { SidebarPanelFooter() }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if files.isEmpty {
            SidebarPanelEmptyState(
                symbol: "doc.text",
                title: "No files yet",
                subtitle: "Files you open with \u{2318}O, or drop on the window, appear here"
            )
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { file in
                        OpenedFileRow(file: file)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }
}
