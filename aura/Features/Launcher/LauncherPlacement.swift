import SwiftUI

/// Where the floating launcher sits: centred on the whole window, horizontally and
/// vertically; it slides up to `raisedFraction` while suggestions are listed. It used to be anchored on the content pane so the
/// sidebar could not push it sideways, which read as off-centre in the window itself.
enum LauncherPlacement {
    /// Distance from the top of the window to the centre of the panel when idle.
    static let verticalFraction: CGFloat = 0.5
    /// Where the panel slides to once suggestions are showing, so the list has room.
    static let raisedFraction: CGFloat = 0.28

    /// Fixed panel width, given up only when the window cannot fit it.
    static let width: CGFloat = 640

    /// Floor for narrow windows; below this the field stops being usable anyway.
    static let minWidth: CGFloat = 320

    /// Panel centre, in the window's own coordinate space.
    static func position(in window: CGRect, raised: Bool = false) -> CGPoint {
        CGPoint(
            x: window.midX,
            y: window.minY + window.height * (raised ? raisedFraction : verticalFraction)
        )
    }

    /// Leaves a 16 pt gutter either side once the window drops under `width`.
    static func width(forWindowWidth available: CGFloat) -> CGFloat {
        min(width, max(minWidth, available - 32))
    }
}
