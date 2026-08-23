import AppKit
import SwiftUI

/// The five navigation marks in Aura's chrome. The artwork is Firefox's own toolbar
/// SVGs (MPL-2.0), which is what gives the row its Zen-like look; see
/// `THIRD_PARTY_NOTICES.md` for the provenance and the two edits made to each file.
enum ToolbarIcon: String, CaseIterable {
    case back
    case forward
    case reload
    case history
    case home

    /// The build flattens `aura/Resources` into `Contents/Resources`, so a bare
    /// `back.svg` would sit next to every other resource. The prefix is the namespace.
    var resourceName: String { "toolbar-" + rawValue }

    private static var cache: [ToolbarIcon: NSImage] = [:]

    @MainActor
    static func image(_ icon: ToolbarIcon) -> NSImage? {
        if let hit = cache[icon] { return hit }
        guard let url = Bundle.main.url(forResource: icon.resourceName, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        // Template so the chrome's foreground colour tints the glyph. The files carry
        // fill="#000000" because AppKit cannot resolve Firefox's `context-fill`.
        image.isTemplate = true
        cache[icon] = image
        return image
    }
}

/// Draws a `ToolbarIcon` at the chrome's icon size, tinted by the ambient foreground.
struct ToolbarIconView: View {
    let icon: ToolbarIcon
    var size: CGFloat = 16

    var body: some View {
        if let image = ToolbarIcon.image(icon) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}
