import SwiftUI

/// Where the floating launcher sits: centred on the whole window, horizontally and 35%
/// down from the window's top edge. It used to be anchored on the content pane so the
/// sidebar could not push it sideways, which read as off-centre in the window itself.
enum LauncherPlacement {
    /// Distance from the top of the window to the centre of the panel.
    static let verticalFraction: CGFloat = 0.35

    /// Fixed panel width, given up only when the window cannot fit it.
    static let width: CGFloat = 640

    /// Floor for narrow windows; below this the field stops being usable anyway.
    static let minWidth: CGFloat = 320

    /// Panel centre, in the window's own coordinate space.
    static func position(in window: CGRect) -> CGPoint {
        CGPoint(
            x: window.midX,
            y: window.minY + window.height * verticalFraction
        )
    }

    /// Leaves a 16 pt gutter either side once the window drops under `width`.
    static func width(forWindowWidth available: CGFloat) -> CGFloat {
        min(width, max(minWidth, available - 32))
    }
}
