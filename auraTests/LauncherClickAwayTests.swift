import AppKit
import SwiftUI
import Testing

@testable import Aura

/// The launcher's click-away monitor compares a click against the panel's measured
/// frame, and the panel is placed with `.offset`. SwiftUI tells an ancestor of an offset
/// the layout frame, not the drawn one: measured from outside the offset, the rect sat
/// in the window's corner and a click on the panel counted as "outside" whenever the two
/// rects did not happen to overlap. This pins, in a real window, which side of the
/// offset the measurement has to sit on, and that the monitor's flip lands inside it.
@MainActor
struct LauncherClickAwayTests {
    private final class Report {
        var frame: CGRect = .zero
    }

    private static let panel = CGRect(x: 300, y: 200, width: 100, height: 50)

    private struct Probe: View {
        let measureInsideOffset: Bool
        let report: Report

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.clear
                if measureInsideOffset {
                    Color.red
                        .frame(width: panel.width, height: panel.height)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            report.frame = $0
                        }
                        .offset(x: panel.minX, y: panel.minY)
                } else {
                    Color.red
                        .frame(width: panel.width, height: panel.height)
                        .offset(x: panel.minX, y: panel.minY)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            report.frame = $0
                        }
                }
            }
        }
    }

    private struct Measured {
        let frame: CGRect
        let window: NSWindow
        let host: NSView
    }

    private func measure(insideOffset: Bool) async -> Measured {
        let report = Report()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: Probe(measureInsideOffset: insideOffset, report: report))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        let deadline = Date().addingTimeInterval(5)
        while report.frame == .zero, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return Measured(frame: report.frame, window: window, host: host)
    }

    /// `.global` is the hosting view's space, and the stack starts under the title bar,
    /// so the drawn panel sits the title bar's height below the offset it was given.
    @Test func measuredInsideTheOffsetTheFrameIsWhereThePanelIsDrawn() async {
        let measured = await measure(insideOffset: true)
        defer { measured.window.close() }
        let frame = measured.frame
        let inset = measured.host.safeAreaInsets.top
        #expect(frame.origin == CGPoint(x: Self.panel.minX, y: Self.panel.minY + inset))
        #expect(frame.size == Self.panel.size)

        // The monitor's arithmetic: a click in the middle of the drawn panel, flipped the
        // way `startClickAway` flips it, lands inside the measured rect.
        let inWindow = measured.host.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        let height = measured.window.contentView?.bounds.height ?? measured.window.frame.height
        let flipped = CGPoint(x: inWindow.x, y: height - inWindow.y)
        #expect(frame.contains(flipped))
    }

    @Test func measuredOutsideTheOffsetTheFrameSitsInTheCorner() async {
        // The trap the fix moved away from: the offset is not in the frame an ancestor is
        // told, so the rect is the panel's size at the stack's corner. If SwiftUI ever
        // reports the drawn frame to an ancestor as well, this fails and the comment in
        // `LauncherView` can go.
        let measured = await measure(insideOffset: false)
        defer { measured.window.close() }
        #expect(measured.frame.origin == CGPoint(x: 0, y: measured.host.safeAreaInsets.top))
        #expect(measured.frame.size == Self.panel.size)
    }
}
