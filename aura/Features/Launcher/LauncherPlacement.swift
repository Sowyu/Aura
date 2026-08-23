import SwiftUI

/// Where the floating launcher sits: dead centre of the window, horizontally and
/// vertically, whatever else the window is doing. It used to be anchored on the content
/// pane, so the sidebar shoved it sideways, and it used to centre the field alone, so the
/// panel drifted downwards as suggestions arrived.
enum LauncherPlacement {
    /// Fixed panel width, given up only when the window cannot fit it.
    static let width: CGFloat = 740

    /// Floor for narrow windows; below this the field stops being usable anyway.
    static let minWidth: CGFloat = 320

    /// Smallest gap between the window's top edge and a panel too tall to centre.
    static let topInset: CGFloat = 16

    /// Top-left of the panel, in whatever space `window` is expressed in.
    ///
    /// Field and suggestion list are one panel and the whole panel is centred, so the
    /// field rides upwards as rows arrive. A panel taller than the window would centre
    /// itself off the top, so it stops `topInset` down and spills off the bottom.
    static func origin(in window: CGRect, panelWidth: CGFloat, panelHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: window.midX - panelWidth / 2,
            y: max(window.minY + topInset, window.midY - panelHeight / 2)
        )
    }

    /// Leaves a 16 pt gutter either side once the window drops under `width`.
    static func width(forWindowWidth available: CGFloat) -> CGFloat {
        min(width, max(minWidth, available - 32))
    }
}
