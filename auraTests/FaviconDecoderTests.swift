import AppKit
import Foundation
@testable import Aura
import Testing

@Suite("Favicon decoding")
struct FaviconDecoderTests {
    private func pngData(side: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// A 512 px apple-touch-icon is stored at full size and only downscaled once, to the
    /// 64 px the 16 pt tab slot needs at 3x.
    @Test("Large icons come back at 64 px")
    func downscalesLargeIcon() throws {
        let image = try #require(FaviconDecoder.decode(try pngData(side: 512)))
        #expect(FaviconDecoder.nativeDimension(of: image) == 64)
    }

    /// Upscaling a bitmap only makes it blurrier, so a small source keeps its own size.
    @Test("Small icons are not upscaled")
    func keepsSmallIcon() throws {
        let image = try #require(FaviconDecoder.decode(try pngData(side: 16)))
        #expect(FaviconDecoder.nativeDimension(of: image) == 16)
    }

    @Test("Pixel size reads representations, not points")
    func pixelSizeUsesRepresentations() throws {
        let image = try #require(NSImage(data: try pngData(side: 128)))
        image.size = NSSize(width: 16, height: 16)
        #expect(FaviconDecoder.pixelSize(of: image) == CGSize(width: 128, height: 128))
    }

    @Test("Garbage bytes decode to nothing")
    func rejectsGarbage() {
        #expect(FaviconDecoder.decode(Data([0x00, 0x01, 0x02])) == nil)
    }
}
