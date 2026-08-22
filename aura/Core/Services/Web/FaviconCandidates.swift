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
        // A declared size never lifts a home-screen tile above a real favicon.
        if isTile(url.format) { return fallbackDimension(for: url.format) }
        if let size = url.size, size.width > 0, size.height > 0 {
            return max(size.width, size.height)
        }
        if url.source.pathExtension.lowercased() == "svg" { return 512 }
        return fallbackDimension(for: url.format)
    }

    private static func isTile(_ format: FaviconFormatType) -> Bool {
        switch format {
        case .appleTouchIcon, .appleTouchIconPrecomposed, .launcherIcon4x, .launcherIcon3x, .launcherIcon2x,
             .launcherIcon1_5x, .launcherIcon1x, .launcherIcon0_75x:
            return true
        default:
            return false
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func fallbackDimension(for format: FaviconFormatType) -> Double {
        switch format {
        // Touch and launcher icons are home-screen tiles: a logo on a solid rounded
        // square. They look like app badges at 16pt, so they rank below any real favicon
        // and only win when a site declares nothing else.
        case .icon: return 64
        case .shortcutIcon: return 48
        case .ico: return 32
        case .appleTouchIcon, .appleTouchIconPrecomposed: return 18
        case .launcherIcon4x: return 17
        case .launcherIcon3x: return 16
        case .launcherIcon2x: return 15
        case .launcherIcon1_5x: return 14
        case .launcherIcon1x: return 13
        case .launcherIcon0_75x: return 12
        case .metaOpenGraphImage, .metaThumbnail: return 0
        }
    }
}
