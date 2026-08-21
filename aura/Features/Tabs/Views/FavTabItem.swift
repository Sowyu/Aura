import AppKit
import SwiftUI

struct FavTabItem: View {
    let tab: Tab
    let isSelected: Bool
    let isDragging: Bool
    let onTap: () -> Void
    let onFavoriteToggle: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    let onMoveToContainer: (TabContainer) -> Void
    /// Passed down rather than queried per tile: one `@Query` per favourite ran a store
    /// fetch for every icon in the grid, only to fill a context menu.
    let containers: [TabContainer]

    @Environment(\.theme) private var theme
    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @EnvironmentObject var privacyMode: PrivacyMode

    @State private var isHovering = false

    var body: some View {
        ZStack {
            if let favicon = tab.favicon, tab.isWebViewReady {
                AsyncImage(
                    url: favicon
                ) { image in
                    image
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                } placeholder: {
                    LocalFavIcon(
                        faviconLocalFile: tab.faviconLocalFile,
                        textColor: Color(.white)
                    )
                }
            } else {
                LocalFavIcon(
                    faviconLocalFile: tab.faviconLocalFile,
                    textColor: Color(.white)
                )
            }

            if tab.isPlayingMedia {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "speaker.wave.2.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 8, height: 8)
                            .foregroundColor(.white.opacity(0.9))
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.6))
                                    .frame(width: 12, height: 12)
                            )
                    }
                }
                .padding(2)
            }
        }
        .onAppear {
            if tabManager.isActive(tab) {
                tab
                    .restoreTransientState(
                        historyManager: historyManager,
                        downloadManager: downloadManager,
                        tabManager: tabManager,
                        isPrivate: privacyMode.isPrivate
                    )
            }
        }
        .foregroundColor(theme.foreground)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .opacity(isDragging ? 0.0 : 1.0)
        .background(backgroundColor)
        .cornerRadius(10)
        .overlay(
            isDragging
                ? RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    theme.invertedSolidWindowBackgroundColor.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
                : isSelected
                ? RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    theme.invertedSolidWindowBackgroundColor,
                    lineWidth: 1
                )
                : nil
        )
        .onTapGesture {
            onTap()
            if !tab.isWebViewReady {
                tab
                    .restoreTransientState(
                        historyManager: historyManager,
                        downloadManager: downloadManager,
                        tabManager: tabManager,
                        isPrivate: privacyMode.isPrivate
                    )
            }
        }
        .onHover { isHovering = $0 }
        .auraContextMenu { contextMenuItems }
    }

    private var contextMenuItems: [AuraMenuItem] {
        Array {
            AuraMenuItem.item("Remove from Favorites", icon: "star.slash", action: onFavoriteToggle)
            AuraMenuItem.item("Duplicate Tab", icon: "doc.on.doc", action: onDuplicate)
            AuraMenuItem.item("Copy Link", icon: "link") {
                ClipboardUtils.copyToClipboard(tab.url.absoluteString)
            }
            AuraMenuItem.separator
            SpaceMenuItems.open(
                url: tab.url,
                from: tab,
                title: "Open in Space",
                spaces: containers
            )
            AuraMenuItem.submenu(
                "Move to Space",
                icon: "arrow.right.square",
                items: containers
                    .filter { $0.id != tab.container.id }
                    .map { container in
                        .item(SpaceMenuItems.label(for: container), icon: container.iconSymbol) {
                            onMoveToContainer(container)
                        }
                    }
            )
            AuraMenuItem.separator
            AuraMenuItem.item("Close Tab", icon: "xmark", isDestructive: true, action: onClose)
        }
    }

    private var backgroundColor: Color {
        if isDragging {
            return theme.activeTabBackground.opacity(0.1)
        } else if isSelected {
            return theme.invertedSolidWindowBackgroundColor.opacity(0.3)
        } else if isHovering {
            return theme.activeTabBackground.opacity(0.3)
        }
        return theme.mutedBackground
    }
}
