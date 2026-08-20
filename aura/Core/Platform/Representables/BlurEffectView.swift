import SwiftUI

struct BlurEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    /// Lets clicks reach whatever is behind. `NSView.hitTest` claims every point inside
    /// its bounds, so a blur spanning the window would otherwise eat every click.
    var isClickThrough = false

    final class ClickThroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = isClickThrough ? ClickThroughEffectView() : NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}
