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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(ContainerManager.self) private var containerManager
    @EnvironmentObject var privacyMode: PrivacyMode

    @State private var isHovering = false
    @ObservedObject private var rowPointer = TabRowPointer.shared

    var body: some View {
        ZStack {
            LocalFavIcon(
                faviconLocalFile: tab.faviconLocalFile, textColor: textColor,
                identity: tab.favicon, revision: tab.faviconRevision, size: 20
            )
            if tab.isPlayingMedia {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 8)).foregroundColor(textColor)
            }
        }

        .foregroundColor(textColor)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .opacity(isDragging ? 0.0 : 1.0)
        .background(backgroundColor, in: .rect(cornerRadius: AuraRadius.row))
        // Only the drag placeholder is outlined. Selection is the fill, same as a tab row.
        .overlay {
            if isDragging {
                RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                    .stroke(
                        theme.invertedSolidWindowBackgroundColor.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                    )
            }
        }
        .overlay(alignment: .trailing) { ContainerStripe(container: tab.browsingContainer) }
        .contentShape(.rect(cornerRadius: AuraRadius.row))
        // `activateTab` rebuilds the web view for a hibernated tab on the way in.
        .onTapGesture { onTap() }
        .onHover { isHovering = $0 }
        .help(tab.title)
        .accessibilityElement(children: .ignore)
        .accessibilityAction { onTap() }
        .accessibilityAction(named: Text("Close Tab")) { onClose() }
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .auraContextMenu { contextMenuItems }
    }

    private var contextMenuItems: [AuraMenuItem] {
        Array {
            AuraMenuItem.item("Remove from Favourites", icon: "star.slash", action: onFavoriteToggle)
            AuraMenuItem.item(
                "Reset to Pinned URL",
                icon: "arrow.counterclockwise",
                isDisabled: !tab.hasLeftPinnedURL
            ) {
                tabManager.resetToPinnedURL(tab)
            }
            AuraMenuItem.item("Set Pinned URL to This Page", icon: "pin") {
                tabManager.replacePinnedURL(tab)
            }
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
            AuraMenuItem.submenu(
                "Open in Container",
                icon: "square.stack.3d.up",
                items: ContainerMenuItems.choices(
                    current: tab.browsingContainer,
                    containers: containerManager.containers
                ) { containerManager.move(tab, to: $0) }
            )
            // No "Close Tab" here on purpose: a favourite is not closable, it is
            // removable. ⌘W parks it (reset + unload); "Remove from Favourites" is the
            // way out of the grid.
        }
    }

    /// A favourite tile carries the same colours as a tab row: idle is bare, hover is a
    /// hint of the active fill, selected is the active fill itself.
    private var backgroundColor: Color {
        if isDragging {
            return theme.activeTabBackground.opacity(0.1)
        } else if rowPointer.pressedRowID == tab.id {
            return theme.activeTabBackground.opacity(colorScheme == .dark ? 0.45 : 0.2)
        } else if isSelected {
            return theme.activeTabBackground
        } else if isHovering {
            return theme.activeTabBackground.opacity(colorScheme == .dark ? 0.3 : 0.1)
        }
        return .clear
    }

    private var textColor: Color {
        isSelected ? .white : theme.foreground
    }
}
