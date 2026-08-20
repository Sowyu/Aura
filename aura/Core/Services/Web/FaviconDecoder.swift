import AppKit

/// Favicons arrive as `.ico`, `.png` or `.svg` at wildly different sizes. Storing the
/// original bytes and decoding them once into a bitmap large enough for a 16 pt slot on
/// a 3x display is what keeps them sharp: a 16 px source drawn at 16 pt is soft on any
/// Retina screen, and re-decoding a 512 px apple-touch-icon per row is a waste.
enum FaviconDecoder {
    /// 16 pt at 3x, with room to spare. Small enough to keep hundreds in memory.
    static let renderedPixels: CGFloat = 64

    /// True pixel dimensions, which `NSImage.size` does not report for multi-page `.ico`
    /// files. Vector representations report zero, so callers must treat that as "scalable".
    static func pixelSize(of image: NSImage) -> CGSize {
        var widest: CGFloat = 0
        var tallest: CGFloat = 0
        for rep in image.representations {
            widest = max(widest, CGFloat(rep.pixelsWide))
            tallest = max(tallest, CGFloat(rep.pixelsHigh))
        }
        guard widest > 0, tallest > 0 else { return image.size }
        return CGSize(width: widest, height: tallest)
    }

    /// The largest edge of the source in pixels, used to reject icons below 32 px.
    static func nativeDimension(of image: NSImage) -> CGFloat {
        let size = pixelSize(of: image)
        return max(size.width, size.height)
    }

    /// Decodes to at most `maxPixels` on the long edge, preserving aspect ratio. Vector
    /// sources are rasterised up to the full box; bitmaps are never upscaled.
    static func decode(_ data: Data, maxPixels: CGFloat = renderedPixels) -> NSImage? {
        guard let source = NSImage(data: data) else { return nil }
        let native = pixelSize(of: source)
        guard native.width > 0, native.height > 0 else { return nil }

        let isVector = !source.representations.isEmpty
            && source.representations.allSatisfy { $0.pixelsWide == 0 }
        let cap: CGFloat = isVector ? .greatestFiniteMagnitude : 1
        let scale = min(cap, maxPixels / max(native.width, native.height))
        let target = CGSize(
            width: max(1, (native.width * scale).rounded()),
            height: max(1, (native.height * scale).rounded())
        )

        source.size = NSSize(width: native.width, height: native.height)
        return render(source, at: target)
    }

    private static func render(_ source: NSImage, at target: CGSize) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: target.width, height: target.height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: rep.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
