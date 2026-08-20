import SwiftUI

/// Where the floating launcher sits.
///
/// It is presented as a window-wide overlay so the dimming covers the chrome too, but it
/// has to read as centred in the *content* pane. Anchoring off the window instead pushes
/// it sideways by half the sidebar width, and flips which way when the sidebar moves to
/// the right, so the pane rect is measured and the panel placed inside it.
enum LauncherPlacement {
    /// Distance from the top of the content pane to the centre of the panel.
    static let verticalFraction: CGFloat = 0.35

    /// Panel centre, in the same coordinate space as `contentPane`.
    static func position(in contentPane: CGRect) -> CGPoint {
        CGPoint(
            x: contentPane.midX,
            y: contentPane.minY + contentPane.height * verticalFraction
        )
    }
}

/// Published by `BrowserContentContainer` so overlays can find the pane it draws.
struct ContentPaneBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
