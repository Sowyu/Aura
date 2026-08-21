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
                .cornerRadius(4)
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
            Spacer()
            actionButton
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
        .opacity(isDragging ? 0.0 : 1.0)
        .background(backgroundColor, in: .rect(cornerRadius: 10))
        .overlay(alignment: .leading) { spaceStripe }
        .overlay(
            isDragging ?
                ConditionallyConcentricRectangle(cornerRadius: 10)
                .stroke(
                    theme.invertedSolidWindowBackgroundColor.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
                : nil
        )
        .contentShape(ConditionallyConcentricRectangle(cornerRadius: 10))
        .onTapGesture {
            onTap()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
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
        }
        .onHover { isHovering = $0 }
        .auraContextMenu { contextMenuItems }
        .animation(AnimationSettings.easeOut(0.15), value: isDragging)
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
        if isHovering, tab.type == .pinned, !tab.isWebViewReady {
            ActionButton(icon: "pin.slash", color: textColor, action: onPinToggle).help("Unpin Tab")
        } else if isHovering {
            ActionButton(icon: "xmark", color: textColor, action: onClose).help("Close Tab")
        }
    }

    /// A 2pt colour rail marking which space the tab belongs to. Spaces left on Auto have
    /// no colour, so most sidebars stay unstriped.
    @ViewBuilder
    private var spaceStripe: some View {
        if let hex = tab.container.iconColorHex, !hex.isEmpty {
            Capsule()
                .fill(Color(hex: hex))
                .frame(width: 2, height: 16)
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
            AuraMenuItem.item(
                "Duplicate Tab",
                icon: "doc.on.doc",
                isDisabled: !tab.isWebViewReady,
                action: onDuplicate
            )
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
            SpaceMenuItems.alwaysOpen(url: tab.url, in: tab.container)
            AuraMenuItem.separator
            AuraMenuItem.item("Close Tab", icon: "xmark", isDestructive: true, action: onClose)
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
        .buttonStyle(InteractiveButtonStyle(cornerRadius: 5, hoverOpacity: 0.18, pressOpacity: 0.3, tint: color))
    }
}
