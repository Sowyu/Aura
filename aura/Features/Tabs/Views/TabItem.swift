import AppKit
import SwiftUI

struct LocalFavIcon: View {
    let faviconLocalFile: URL?
    let textColor: Color

    @State private var image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        } else {
            Image(systemName: "globe")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundColor(textColor)
                .onAppear(perform: loadFavicon)
        }
    }

    private func loadFavicon() {
        guard let localURL = faviconLocalFile,
              FileManager.default.fileExists(atPath: localURL.path) else { return }

        // Reading and decoding both block; the service memoises the 64 px result so only
        // the first row to ask for a given file pays for it.
        DispatchQueue.global(qos: .utility).async {
            guard let loadedImage = FaviconService.shared.icon(atFile: localURL) else { return }
            DispatchQueue.main.async {
                self.image = loadedImage
            }
        }
    }
}

struct FavIcon: View {
    let isWebViewReady: Bool
    let favicon: URL?
    let faviconLocalFile: URL?
    let textColor: Color
    var isPlayingMedia: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let favicon, isWebViewReady {
                AsyncImage(
                    url: favicon
                ) { image in
                    image
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } placeholder: {
                    LocalFavIcon(
                        faviconLocalFile: faviconLocalFile,
                        textColor: textColor
                    )
                }
            } else {
                LocalFavIcon(
                    faviconLocalFile: faviconLocalFile,
                    textColor: textColor
                )
            }

            if isPlayingMedia {
                Image(systemName: "speaker.wave.2.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 8, height: 8)
                    .foregroundColor(textColor.opacity(0.8))
            }
        }
        .frame(width: isPlayingMedia ? 28 : 16, height: 16)
    }
}

struct TabItem: View {
    let tab: Tab
    let isSelected: Bool
    let isDragging: Bool
    let onTap: () -> Void
    let onPinToggle: () -> Void
    let onFavoriteToggle: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    let onMoveToContainer: (TabContainer) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(TabManager.self) private var tabManager
    @Environment(HistoryManager.self) private var historyManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(ContainerManager.self) private var containerManager
    @EnvironmentObject var privacyMode: PrivacyMode
    let availableContainers: [TabContainer]

    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack {
            FavIcon(
                isWebViewReady: tab.isWebViewReady,
                favicon: tab.favicon,
                faviconLocalFile: tab.faviconLocalFile,
                textColor: textColor,
                isPlayingMedia: tab.isPlayingMedia
            )
            tabTitle
            Spacer(minLength: 4)
            // A pinned row that navigated away from its pinned URL offers the way back
            // on hover, next to the close button. Pinned only: a favourite tile has no
            // room for it and its context menu carries the same reset.
            if tab.type == .pinned, tab.hasLeftPinnedURL {
                ActionButton(icon: "arrow.counterclockwise", color: textColor) {
                    tabManager.resetToPinnedURL(tab)
                }
                .help("Back to Pinned URL")
                .accessibilityLabel(Text("Back to Pinned URL"))
                .frame(width: 20, height: 20)
                .opacity(isHovering ? 1 : 0)
            }
            // Always laid out, so hovering toggles opacity only: nothing moves or
            // reflows. Hit-testable even while invisible: after a close the next row
            // slides under a stationary pointer, `onHover` does not re-fire, and
            // gating hits on `isHovering` sent that click to the row's tap gesture —
            // selecting the tab the user was trying to close.
            actionButton
                .frame(width: 20, height: 20)
                .opacity(isHovering ? 1 : 0)
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
        .padding(8)
        .opacity(isDragging ? 0.45 : 1.0)
        .background(backgroundColor, in: .rect(cornerRadius: AuraRadius.row))
        .overlay(alignment: .trailing) { ContainerStripe(container: tab.browsingContainer) }
        .contentShape(ConditionallyConcentricRectangle(cornerRadius: AuraRadius.row))
        // `activateTab` rebuilds the web view for a hibernated tab on the way in, so
        // there is nothing to chase here.
        .onTapGesture { onTap() }
        .onHover { isHovering = $0 }
        // The row is a button made of a gesture, so it says so itself; the close button
        // inside it keeps its own label.
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .auraContextMenu { contextMenuItems }
        .geometryGroup()
    }

    private var tabTitle: some View {
        Text(tab.title)
            .font(.system(size: 13))
            .foregroundColor(textColor)
            .lineLimit(1)
    }

    private var backgroundColor: Color {
        if isDragging {
            return theme.activeTabBackground.opacity(0.1)
        } else if isSelected {
            return theme.activeTabBackground
        } else if isHovering {
            if colorScheme == .dark {
                return theme.activeTabBackground.opacity(0.3)
            } else {
                return theme.activeTabBackground.opacity(0.1)
            }
        }
        return .clear
    }

    private var textColor: Color {
        isSelected ? .white : theme.foreground
    }

    @ViewBuilder
    private var actionButton: some View {
        if tab.type == .pinned, !tab.isWebViewReady {
            ActionButton(icon: "pin.slash", color: textColor, action: onPinToggle)
                .help("Unpin Tab")
                .accessibilityLabel(Text("Unpin Tab"))
        } else {
            ActionButton(icon: "xmark", color: textColor, action: onClose)
                .help("Close Tab")
                .accessibilityLabel(Text("Close Tab"))
        }
    }

    private var contextMenuItems: [AuraMenuItem] {
        Array {
            AuraMenuItem.item(
                tab.type == .pinned ? "Unpin Tab" : "Pin Tab",
                icon: tab.type == .pinned ? "pin.slash" : "pin",
                action: onPinToggle
            )
            AuraMenuItem.item(
                tab.type == .fav ? "Remove from Favorites" : "Add to Favorites",
                icon: tab.type == .fav ? "star.slash" : "star",
                action: onFavoriteToggle
            )
            if tab.type != .normal {
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
            }
            // Duplicating works without a live web view: a hibernated tab and an
            // aura:// page both copy fine.
            AuraMenuItem.item("Duplicate Tab", icon: "doc.on.doc", action: onDuplicate)
            AuraMenuItem.separator
            AuraMenuItem.item("Copy Link", icon: "link") {
                ClipboardUtils.copyToClipboard(tab.url.absoluteString)
            }
            SpaceMenuItems.open(
                url: tab.url,
                from: tab,
                title: "Open in Space",
                spaces: availableContainers
            )
            if availableContainers.count > 1 {
                AuraMenuItem.submenu(
                    "Move to Space",
                    icon: "arrow.right.square",
                    items: availableContainers
                        .filter { $0.id != tab.container.id }
                        .map { container in
                            .item(SpaceMenuItems.label(for: container), icon: container.iconSymbol) {
                                onMoveToContainer(container)
                            }
                        }
                )
            }
            AuraMenuItem.submenu(
                "Open in Container",
                icon: "square.stack.3d.up",
                items: ContainerMenuItems.choices(
                    current: tab.browsingContainer,
                    containers: containerManager.containers
                ) { containerManager.move(tab, to: $0) }
            )
            SpaceMenuItems.alwaysOpen(url: tab.url, in: tab.container)
            AuraMenuItem.separator
            // On a pinned tab the menu's close is the deliberate one: `onClose` (the
            // row button and ⌘W) parks a pinned tab, this genuinely removes it.
            AuraMenuItem.item("Close Tab", icon: "xmark", isDestructive: true) {
                if tab.type == .normal {
                    onClose()
                } else {
                    tabManager.deleteTab(tab: tab)
                }
            }
        }
    }
}

struct ActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void

    /// The glyph stays 10pt; the hit box is 20pt square, because a 16pt target on a
    /// 40pt row is a coin-toss for the close button.
    private static let hitSize: CGFloat = 20

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .frame(width: Self.hitSize, height: Self.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(
            InteractiveButtonStyle(
                cornerRadius: AuraRadius.button,
                hoverOpacity: 0.18,
                pressOpacity: 0.3,
                tint: color
            )
        )
    }
}

/// The tab's browsing container as a 2pt rail on the trailing edge of a row. The 4pt
/// inset keeps it clear of the row's 10pt corner and outside the close button's 20pt
/// slot, so nothing moves when the button appears. Blank for a tab in no container,
/// which is most of them.
struct ContainerStripe: View {
    let container: BrowsingContainer?

    var body: some View {
        if let container {
            Capsule()
                .fill(Color(hex: container.colorHex))
                .frame(width: 2, height: 16)
                .padding(.trailing, 4)
        }
    }
}
