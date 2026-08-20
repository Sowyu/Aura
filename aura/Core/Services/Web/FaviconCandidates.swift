import FaviconFinder
import Foundation

/// Orders the icons a page declares so the best one is downloaded first.
///
/// `FaviconFinder` hands back everything it finds in `<head>`, including the OpenGraph
/// share image. A 1200x630 marketing banner squashed into a 16 pt tab row is the main
/// reason Aura's favicons read worse than other browsers', so those are dropped, and the
/// remaining links are ranked by declared size with a per-format guess as the tiebreak.
enum FaviconCandidates {
    /// Below this the icon is treated as a fallback, not a result worth stopping at.
    static let minimumPixels: CGFloat = 32

    static func ranked(_ urls: [FaviconURL]) -> [FaviconURL] {
        urls
            .filter { !isSocialPreview($0) }
            .sorted { score(for: $0) > score(for: $1) }
    }

    /// `og:image` and `thumbnail` are share cards, never icons.
    static func isSocialPreview(_ url: FaviconURL) -> Bool {
        url.format == .metaOpenGraphImage || url.format == .metaThumbnail
    }

    /// Longest declared edge, or a guess from the format when the page declares no size.
    static func score(for url: FaviconURL) -> Double {
        if let size = url.size, size.width > 0, size.height > 0 {
            return max(size.width, size.height)
        }
        if url.source.pathExtension.lowercased() == "svg" { return 512 }
        return fallbackDimension(for: url.format)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func fallbackDimension(for format: FaviconFormatType) -> Double {
        switch format {
        case .appleTouchIcon, .appleTouchIconPrecomposed: return 180
        case .launcherIcon4x: return 192
        case .launcherIcon3x: return 144
        case .launcherIcon2x: return 96
        case .launcherIcon1_5x: return 72
        case .launcherIcon1x: return 48
        case .launcherIcon0_75x: return 36
        case .icon: return 32
        case .shortcutIcon: return 24
        case .ico: return 16
        case .metaOpenGraphImage, .metaThumbnail: return 0
        }
    }
}
