import AppKit
import Foundation
@testable import Aura
import Testing
import os

@Suite("Favicon decoding")
struct FaviconDecoderTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func simultaneousDisplayAndSaveRequestsShareOneDownload() async throws {
        let data = try pngData(side: 64)
        let image = try #require(NSImage(data: data))
        let sourceURL = try #require(URL(string: "https://example.test/favicon.ico"))
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let service = FaviconService(fetchPayload: { _ in
            fetches.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(20))
            return FaviconPayload(image: image, data: data, sourceURL: sourceURL)
        })
        // A non-directory parent makes every save fail without creating any files.
        let destination = URL(fileURLWithPath: "/dev/null/aura-favicon")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var remaining = 40
            let completed = {
                remaining -= 1
                if remaining == 0 { continuation.resume() }
            }
            for _ in 0 ..< 20 {
                service.fetchFaviconSync(for: "https://example.test") { result in
                    #expect(result === image)
                    completed()
                }
                service
                    .downloadAndSaveFavicon(for: "example.test", faviconURL: sourceURL, to: destination) { _, success in
                        #expect(!success)
                        completed()
                    }
            }
        }
        #expect(fetches.withLock { $0 } == 1)

        service.originalBytes.removeAllObjects()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            service.downloadAndSaveFavicon(for: "example.test", faviconURL: sourceURL, to: destination) { _, success in
                #expect(!success)
                continuation.resume()
            }
        }
        #expect(fetches.withLock { $0 } == 2)
    }

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

    /// The favicon caches used to be unbounded dictionaries, so a long session kept an
    /// entry for every domain ever seen.
    @Test func boundedCacheDropsTheOldestEntryPastItsLimit() {
        var cache = BoundedCache<Int, String>(limit: 3)
        for index in 0 ..< 5 { cache[index] = "v\(index)" }

        #expect(cache.count == 3)
        #expect(cache[0] == nil)
        #expect(cache[1] == nil)
        #expect(cache[4] == "v4")

        // Overwriting an existing key must not re-queue it for eviction.
        cache[2] = "updated"
        #expect(cache.count == 3)
        #expect(cache[2] == "updated")

        cache.removeValue(forKey: 2)
        #expect(cache.count == 2)
        #expect(cache[2] == nil)

        #expect(FaviconService.cacheLimit == 512)
    }

    /// The two NSCaches were unbounded: the raw bytes of every favicon ever downloaded
    /// and every decoded icon file stayed resident for the life of the process.
    @Test("Byte and image caches carry count and cost ceilings")
    func nsCachesAreBounded() {
        let service = FaviconService.shared

        #expect(service.originalBytes.countLimit == 256)
        #expect(service.originalBytes.totalCostLimit == 32 * 1024 * 1024)
        #expect(service.fileImages.countLimit == 256)
        #expect(service.fileImages.totalCostLimit == 64 * 1024 * 1024)
    }

    /// A ceiling only evicts if the entries declare a cost, so the icon cost has to be
    /// the bitmap size rather than NSImage's point size.
    @Test("Image cost is the pixel bitmap, not the point size")
    func imageCostUsesPixels() throws {
        let image = try #require(NSImage(data: try pngData(side: 64)))
        image.size = NSSize(width: 16, height: 16)

        #expect(FaviconService.imageCost(image) == 64 * 64 * 4)
    }
}
