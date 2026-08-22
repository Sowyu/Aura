import SwiftUI

/// One visit in the history panel. Dumb on purpose: every action is a closure the panel
/// supplies, so the row needs no managers and renders in a preview.
///
/// Ported from Nook's `HistoryRowView` (`Nook/Components/Sidebar/Menu/
/// SidebarMenuHistoryTab.swift`) by Maciek Bagiński, GPL-3.0. Restyled to Aura's flat
/// chrome: no per-row favicon fetch, no scale transitions, hover fades in 0.1 s.
struct HistoryPanelRow: View {
    let item: History
    let onOpen: () -> Void
    let onOpenInNewTab: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var displayTitle: String {
        item.title.isEmpty ? item.urlString : item.title
    }

    var body: some View {
        HStack(spacing: 10) {
            SiteFaviconView(host: item.url.host ?? "", size: 16, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(item.url.host ?? item.urlString)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if isHovered {
                hoverActions
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
            withAnimation(AnimationSettings.easeOut(0.1)) {
                isHovered = hovering
            }
        }
        .onTapGesture(perform: onOpen)
        .auraContextMenu { menuItems }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            actionButton(icon: "plus.square.on.square", help: "Open in New Tab", action: onOpenInNewTab)
            actionButton(icon: "trash", help: "Remove from History", action: onDelete)
        }
    }

    private func actionButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.interactive(cornerRadius: 6))
        .help(help)
    }

    private var menuItems: [AuraMenuItem] {
        [
            .item("Open", icon: "arrow.turn.down.right", action: onOpen),
            .item("Open in New Tab", icon: "plus.square.on.square", action: onOpenInNewTab),
            .separator,
            .item("Copy Link", icon: "link") {
                ClipboardUtils.copyToClipboard(item.urlString)
            },
            .item("Remove from History", icon: "trash", action: onDelete)
        ]
    }
}
