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
///
/// Told apart on macOS 27 (Xcode 27.0 beta 27A5218g), 2026-08-25: it is the second.
/// Pages on the bundle pool went blank for the user while the snapshot probe kept
/// saying `painted`, and a page's own `requestAnimationFrame` loop stopped after two
/// frames with `document.visibilityState` still `visible`. So the fixture now counts
/// its own frames as well, next to a control page on the ordinary WebContent service
/// loaded the same way. A counter that stands still while the control's climbs is the
/// purge, and it outranks the snapshot. Both readings need a window the window server
/// treats as visible, which is why the host window keeps one point on screen instead
/// of sitting at (-20000, -20000): rAF does not tick in a window nobody could see.
/// The window server's own image of each probe window is the third reading, and the
/// most direct one: it is what the user would see.
///
/// The failure itself is answered in `AuraWebBundleSupport.m` (the RunningBoard shim);
/// this probe is what catches the day that answer stops working.
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
            </head><body><script>\(framesScript)</script></body></html>
            """
        }

        /// The fixture's own rendering-update counter. `requestAnimationFrame` only
        /// fires when the web process runs a rendering update, and a purged page
        /// stops getting those; a snapshot cannot tell, because `takeSnapshot`
        /// re-renders on demand.
        static let framesScript =
            "window.__auraFrames=0;(function t(){window.__auraFrames++;window.requestAnimationFrame(t)})();"

        /// Frames the fixture counted during the settle, on the bundle pool and on the
        /// control page, reduced to a verdict.
        ///
        /// The control is what makes this safe: a probe window nothing ticks in (covered,
        /// off screen, a display that is asleep) reads zero on both, and that is the
        /// probe's own problem, not the browser's. Only a control that demonstrably
        /// ticks while the bundle page stands still counts against the stack. A bundle
        /// page ticking at a throttled rate is not the purge either, so it decides
        /// nothing on its own.
        static func frameVerdict(bundle: Int, control: Int, settle: TimeInterval) -> Verdict {
            // 15 fps over the settle: a quarter of a 60 Hz display, and far above the
            // 1 fps WebKit throttles hidden pages to.
            let healthy = Int(settle * 15)
            // Two frames is what the failure produced on the real thing.
            let dead = 5
            guard control >= healthy else { return .inconclusive }
            if bundle <= dead {
                return .blank
            }
            return bundle >= healthy ? .painted : .inconclusive
        }

        /// What the window server composites for the two probe windows, reduced to a
        /// verdict. The control again keeps a capture that failed for the probe's own
        /// reasons (no image, a window off every screen) from counting.
        static func screenVerdict(bundle: Sample?, control: Sample?) -> Verdict {
            guard let bundle, let control, control.fixtureShare >= 0.5 else { return .inconclusive }
            if bundle.fixtureShare >= 0.5 {
                return .painted
            }
            return bundle.fixtureShare < 0.1 ? .blank : .inconclusive
        }

        /// The readings combined. The screen is what the user sees, so it decides when
        /// it can; frames measure the failure mechanism and decide otherwise. The
        /// snapshot can only make things worse: painted-then-blank is still the purge,
        /// but `painted` from it certifies nothing, because that is exactly what it
        /// said on the run whose pages were blank on screen. Nothing conclusive either
        /// way is inconclusive, and the caller retries once before failing toward uBO
        /// Lite.
        static func combined(snapshot: Verdict, frames: Verdict, screen: Verdict) -> Verdict {
            if screen == .painted {
                return snapshot == .blank ? .blank : .painted
            }
            if screen == .blank || frames == .blank || snapshot == .blank {
                return .blank
            }
            return frames == .painted ? .painted : .inconclusive
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
                   abs(blue - fixtureLevel) <= tolerance
                {
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
            if sample.fixtureShare >= 0.5 {
                return .painted
            }
            if sample.dominantShare >= 0.98 {
                return .blank
            }
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
            // The control is a plain page on the ordinary WebContent service: what
            // healthy looks like on this machine right now.
            let bundle = Page(pool: pool, slot: 0)
            let control = Page(pool: WKProcessPool(), slot: 1)
            defer {
                bundle.tearDown()
                control.tearDown()
            }

            bundle.view.loadHTMLString(fixtureHTML, baseURL: nil)
            control.view.loadHTMLString(fixtureHTML, baseURL: nil)
            await waitUntilLoaded(bundle.view)
            await waitUntilLoaded(control.view)
            // The control's first frames lag the load by however long its web process
            // and the window server take to get going; on the first run of a launch
            // that was the whole settle, and it read zero. The baseline waits for it.
            await waitUntilTicking(control.view)
            let first = await snapshot(of: bundle.view)
            let bundleStart = await frames(in: bundle.view)
            let controlStart = await frames(in: control.view)
            try? await Task.sleep(for: .seconds(settle))
            let second = await snapshot(of: bundle.view)
            let bundleFrames = await frames(in: bundle.view) - bundleStart
            let controlFrames = await frames(in: control.view) - controlStart

            let bundleScreen = screenSample(of: bundle.window)
            let controlScreen = screenSample(of: control.window)

            let bySnapshot: Verdict = if let first, let second {
                verdict(afterFirstPaint: sample(first), settled: sample(second))
            } else {
                .inconclusive
            }
            let byFrames = frameVerdict(bundle: bundleFrames, control: controlFrames, settle: settle)
            let byScreen = screenVerdict(bundle: bundleScreen, control: controlScreen)
            let result = combined(snapshot: bySnapshot, frames: byFrames, screen: byScreen)
            log.info("""
            paint probe verdict: \(String(describing: result), privacy: .public) \
            (snapshot \(String(describing: bySnapshot), privacy: .public), \
            frames bundle \(bundleFrames, privacy: .public) control \(controlFrames, privacy: .public), \
            screen \(String(describing: byScreen), privacy: .public): fixture share bundle \
            \(bundleScreen.map { String(format: "%.2f", $0.fixtureShare) } ?? "n/a", privacy: .public) \
            control \(controlScreen.map { String(format: "%.2f", $0.fixtureShare) } ?? "n/a", privacy: .public))
            """)
            return result
        }

        /// One fixture page and the window that makes WebKit render it.
        @MainActor
        private struct Page {
            let view: WKWebView
            let window: NSWindow

            init(pool: WKProcessPool, slot: Int) {
                let configuration = WKWebViewConfiguration()
                configuration.processPool = pool
                view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), configuration: configuration)
                window = hostWindow(for: view, slot: slot)
            }

            func tearDown() {
                view.stopLoading()
                window.orderOut(nil)
                window.contentView = nil
            }
        }

        /// What the fixture's counter reads now; zero if the page cannot be asked.
        @MainActor
        private static func frames(in view: WKWebView) async -> Int {
            let value = try? await view.evaluateJavaScript("window.__auraFrames")
            return (value as? NSNumber)?.intValue ?? 0
        }

        /// A borderless window with exactly one point inside the screen, in the corner
        /// the Dock and menu bar leave free. WebKit only commits layers, and only runs
        /// rendering updates, for a page in a window the window server counts as
        /// visible; a window off every screen is not one, and the frame counter would
        /// read zero on a healthy stack. One point of flat grey for a couple of seconds
        /// is what the user can see of it. It never takes the first responder away from
        /// what they are typing in, and clicks pass through it.
        @MainActor
        private static func hostWindow(for view: NSView, slot: Int) -> NSWindow {
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1, height: 1)
            // Each probe window gets its own corner (slot 0 bottom-left, slot 1
            // top-left), so neither occludes the other's point: an occluded window is
            // not visible to WebKit and its page stops ticking.
            window.setFrameOrigin(NSPoint(
                x: screen.minX + 1 - view.frame.width,
                y: slot == 0 ? screen.minY + 1 - view.frame.height : screen.maxY - 1
            ))
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

        /// What the window server is compositing for `window`, or nil when the capture
        /// is refused or empty. Unlike `takeSnapshot`, this cannot be satisfied by the
        /// web process re-rendering on demand.
        @MainActor
        static func screenSample(of window: NSWindow) -> Sample? {
            guard window.windowNumber > 0,
                  let image = AuraCaptureWindow(UInt32(window.windowNumber)),
                  image.width > 1, image.height > 1
            else { return nil }
            return sample(image)
        }

        /// Polls the fixture's counter until it has moved, or gives up after `timeout`.
        @MainActor
        private static func waitUntilTicking(_ view: WKWebView, timeout: TimeInterval = 1.5) async {
            let deadline = Date().addingTimeInterval(timeout)
            while await frames(in: view) == 0, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
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
