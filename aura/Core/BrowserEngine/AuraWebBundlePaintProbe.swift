import AppKit
import CoreGraphics
import Foundation
import os
@preconcurrency import WebKit

/// The visual half of the injected bundle's health check.
///
/// The message probe in `AuraWebBundle.probe` proves the private-API stack answers. It
/// says nothing about the thing that actually broke full uBlock Origin here: pages
/// hosted in WebKit's Development WebContent service paint once and then go blank,
/// because that service cannot hold a RunningBoard foreground assertion and its layers
/// are purged about a second later. A stack that answers and does not paint is the worst
/// of the two failures, because the browser looks broken rather than unblocked.
///
/// So when full uBO is on, a throwaway page is loaded on the bundle's pool, snapshotted
/// twice, and the two readings are compared. Painted then blank is the purge signature
/// and takes blocking off for the session, which puts uBO Lite back. Anything else is
/// left alone.
///
/// Verified by hand per OS beta. The reducers below are covered by tests on synthetic
/// images, but whether an offscreen probe window reproduces the purge at all is a
/// question only a real run on a real build answers, and the answer changes with the OS.
///
/// Measured on macOS 26 beta (build 26A5416b), 2026-08-22, through the gated test
/// `WebBundleTests.thePaintProbeReachesAVerdict`: verdict `painted`, while the same run
/// logged `Failed to acquire RBS assertion` for every WebProcess assertion. So either
/// this build no longer purges the layers, or `takeSnapshot` re-renders in the web
/// process and cannot see a purge that only affects what the window server composites.
/// Until that is told apart, treat a `painted` verdict as "no evidence of the failure"
/// rather than as proof the stack is healthy. The fallback that matters to a user is
/// the same either way: a blank verdict restores uBO Lite, and so does a silent bundle.
extension AuraWebBundle {
    enum PaintProbe {
        private static let log = Logger(subsystem: "com.aurabrowser.app", category: "webbundle")

        /// The fixture paints a mid grey, one level on all three channels. Grey rather
        /// than a saturated colour because the snapshot comes back in whatever colour
        /// space the display uses, and grey survives the conversion back to sRGB almost
        /// exactly, while a saturated colour can move further than any sane tolerance.
        /// It is also nothing WebKit paints by itself, so finding it means the page did.
        static let fixtureLevel = 96

        /// How far a channel may drift and still count as the fixture colour.
        private static let tolerance = 16

        /// One page, one colour, no network. Written from the level above so the page
        /// and the matcher cannot drift apart.
        static var fixtureHTML: String {
            let hex = String(format: "#%02x%02x%02x", fixtureLevel, fixtureLevel, fixtureLevel)
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <style>html,body{margin:0;height:100%;background:\(hex)}</style>
            </head><body></body></html>
            """
        }

        /// What one snapshot holds, reduced to three numbers so the rule below is
        /// arithmetic rather than image handling.
        struct Sample: Equatable {
            var pixels: Int
            /// Share of pixels within tolerance of the fixture colour, 0 to 1.
            var fixtureShare: Double
            /// Share held by the single most common colour, 0 to 1.
            var dominantShare: Double
        }

        enum Verdict: Equatable {
            case painted
            case blank
            /// Neither. Nothing is switched off on a reading this weak.
            case inconclusive
        }

        /// Reduces a snapshot to `Sample` by redrawing it small in sRGB and counting.
        ///
        /// Redrawn rather than read in place: a snapshot arrives in the display's colour
        /// space with its own row padding, and 32 by 32 is enough to tell one flat colour
        /// from another while costing nothing.
        static func sample(_ image: CGImage, side: Int = 32) -> Sample {
            guard side > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
                return Sample(pixels: 0, fixtureShare: 0, dominantShare: 0)
            }
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let base = buffer.baseAddress,
                      let context = CGContext(
                          data: base,
                          width: side,
                          height: side,
                          bitsPerComponent: 8,
                          bytesPerRow: side * 4,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      )
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn else { return Sample(pixels: 0, fixtureShare: 0, dominantShare: 0) }
            return count(pixels, total: side * side)
        }

        /// Buckets every pixel by its top four bits per channel, which is coarse enough
        /// that dithering and colour conversion do not split one flat fill into two
        /// buckets, and fine enough that two different flat fills never share one.
        private static func count(_ pixels: [UInt8], total: Int) -> Sample {
            guard total > 0 else { return Sample(pixels: 0, fixtureShare: 0, dominantShare: 0) }
            var buckets: [Int: Int] = [:]
            var fixture = 0
            for index in stride(from: 0, to: total * 4, by: 4) {
                let red = Int(pixels[index])
                let green = Int(pixels[index + 1])
                let blue = Int(pixels[index + 2])
                if abs(red - fixtureLevel) <= tolerance,
                   abs(green - fixtureLevel) <= tolerance,
                   abs(blue - fixtureLevel) <= tolerance {
                    fixture += 1
                }
                let bucket = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)
                buckets[bucket, default: 0] += 1
            }
            return Sample(
                pixels: total,
                fixtureShare: Double(fixture) / Double(total),
                dominantShare: Double(buckets.values.max() ?? 0) / Double(total)
            )
        }

        /// What one snapshot on its own says.
        ///
        /// Deliberately lopsided. Half the fixture colour is enough to call it painted,
        /// while blank needs the image to be one flat colour that is not the fixture's:
        /// a purged layer tree leaves white, black or nothing at all.
        static func reading(for sample: Sample) -> Verdict {
            guard sample.pixels > 0 else { return .inconclusive }
            if sample.fixtureShare >= 0.5 { return .painted }
            if sample.dominantShare >= 0.98 { return .blank }
            return .inconclusive
        }

        /// The rule the probe acts on: painted first, blank a couple of seconds later.
        ///
        /// The first reading is what makes this safe to run in a window the user cannot
        /// see. A surface that never painted at all reads blank both times, and that is
        /// the probe's own fault rather than the browser's, so it decides nothing.
        static func verdict(afterFirstPaint first: Sample, settled second: Sample) -> Verdict {
            guard reading(for: first) == .painted else { return .inconclusive }
            return reading(for: second) == .blank ? .blank : .painted
        }

        /// Loads the fixture on the bundle's pool and returns what it saw. Returns
        /// `.inconclusive` for everything that is not a clean answer, including a
        /// snapshot the OS refused to take.
        @MainActor
        static func run(pool: WKProcessPool, settle: TimeInterval = 2) async -> Verdict {
            let configuration = WKWebViewConfiguration()
            configuration.processPool = pool
            // The fixture runs the same keep-alive and foreground-priority levers real
            // pages get, so the verdict is about the stack the user will actually be
            // on, mitigations included.
            AuraPaintKeepAlive.apply(to: configuration)
            AuraWebBundle.applyForegroundPriorityIfWanted(to: configuration)
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), configuration: configuration)
            let window = hostWindow(for: view)
            defer {
                view.stopLoading()
                window.orderOut(nil)
                window.contentView = nil
            }

            view.loadHTMLString(fixtureHTML, baseURL: nil)
            await waitUntilLoaded(view)
            guard let first = await snapshot(of: view) else { return .inconclusive }
            try? await Task.sleep(for: .seconds(settle))
            guard let second = await snapshot(of: view) else { return .inconclusive }

            let result = verdict(afterFirstPaint: sample(first), settled: sample(second))
            log.info("paint probe verdict: \(String(describing: result), privacy: .public)")
            return result
        }

        /// A borderless window placed off every screen. WebKit only commits layers for a
        /// page that belongs to a window, and this one must never flash in front of the
        /// user or take the first responder away from what they are typing in.
        @MainActor
        private static func hostWindow(for view: NSView) -> NSWindow {
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            return window
        }

        /// Polls rather than taking a navigation delegate: the fixture is a string with
        /// no subresources, so this settles in a frame or two, and a delegate object
        /// would have to outlive the call for WebKit to hold it weakly.
        @MainActor
        private static func waitUntilLoaded(_ view: WKWebView, timeout: TimeInterval = 5) async {
            let deadline = Date().addingTimeInterval(timeout)
            while view.isLoading, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }

        @MainActor
        private static func snapshot(of view: WKWebView) async -> CGImage? {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = 64
            let image: NSImage? = await withCheckedContinuation { continuation in
                view.takeSnapshot(with: configuration) { image, error in
                    if let error {
                        log.error("paint probe snapshot failed: \(error.localizedDescription, privacy: .public)")
                    }
                    continuation.resume(returning: image)
                }
            }
            return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }
}
