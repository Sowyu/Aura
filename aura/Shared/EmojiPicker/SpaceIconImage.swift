import AppKit

/// Loads the bundled space-icon SVGs. The build flattens `aura/Resources` into
/// `Contents/Resources`, so the lookup is flat rather than by subdirectory.
@MainActor
enum SpaceIconImage {
    private static var cache: [String: NSImage] = [:]

    static func load(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        // Template so the swatch colour tints the glyph instead of it drawing flat black.
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
