import SwiftUI

struct BlurEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    /// Lets clicks reach whatever is behind. `NSView.hitTest` claims every point inside
    /// its bounds, so a blur spanning the window would otherwise eat every click.
    var isClickThrough = false
    /// Rounded rects, in this view's top-left coordinates, where the material is cut
    /// away so whatever sits behind shows through sharp.
    var holes: [CGRect] = []
    var holeRadius: CGFloat = 15

    final class EffectView: NSVisualEffectView {
        var isClickThrough = false
        var holeRadius: CGFloat = 15
        var holes: [CGRect] = [] {
            didSet { if holes != oldValue { rebuildMask() } }
        }
        private var maskedSize: CGSize = .zero

        override func hitTest(_ point: NSPoint) -> NSView? {
            isClickThrough ? nil : super.hitTest(point)
        }

        override func layout() {
            super.layout()
            if bounds.size != maskedSize { rebuildMask() }
        }

        /// `maskImage` is stretched over the bounds, so the image is rebuilt at the exact
        /// bounds size and the holes map 1:1. `flipped: true` puts the origin top-left.
        private func rebuildMask() {
            maskedSize = bounds.size
            guard !holes.isEmpty, bounds.width > 0, bounds.height > 0 else {
                maskImage = nil
                return
            }
            let holes = holes
            let radius = holeRadius
            let image = NSImage(size: bounds.size, flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.setFillColor(NSColor.black.cgColor)
                context.fill(rect)
                context.setBlendMode(.clear)
                for hole in holes {
                    context.addPath(CGPath(
                        roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil
                    ))
                }
                context.fillPath()
                return true
            }
            maskImage = image
        }
    }

    func makeNSView(context: Context) -> EffectView {
        let visualEffectView = EffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        visualEffectView.isClickThrough = isClickThrough
        visualEffectView.holeRadius = holeRadius
        visualEffectView.holes = holes
        return visualEffectView
    }

    func updateNSView(_ nsView: EffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isClickThrough = isClickThrough
        nsView.holeRadius = holeRadius
        nsView.holes = holes
    }
}
