import SwiftUI

/// One dial for the window chrome's motion. With reduce motion on, every duration that
/// goes through here becomes 0, so the sidebar, toolbar, launcher and menus cut straight
/// to their end state instead of sliding.
///
/// The flag is read from `UserDefaults` rather than observed: a view picks the new value
/// up on its next redraw, which for chrome is the same frame the user toggles anything.
enum AnimationSettings {
    static var reduceMotion: Bool {
        UserDefaults.standard.bool(forKey: SettingsStore.reduceMotionKey)
    }

    static func duration(_ seconds: Double) -> Double {
        reduceMotion ? 0 : seconds
    }

    static func easeOut(_ seconds: Double) -> Animation {
        .easeOut(duration: duration(seconds))
    }

    /// A spring has no duration to zero out, so reduce motion swaps it for an
    /// instant ease.
    static func spring(response: Double, dampingFraction: Double) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0)
            : .spring(response: response, dampingFraction: dampingFraction)
    }
}
