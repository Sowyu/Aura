import SwiftUI

/// One dial for the window chrome's motion. With reduce motion on, every duration that
/// goes through here becomes 0, so the sidebar, toolbar, launcher and menus cut straight
/// to their end state instead of sliding.
///
/// The flag is read from `UserDefaults` rather than observed: a view picks the new value
/// up on its next redraw, which for chrome is the same frame the user toggles anything.
///
/// It is read once and cached, because `duration`/`easeOut`/`spring` are called from
/// view bodies at 84 sites; a `UserDefaults` lookup per animated modifier per frame is
/// pure overhead. `SettingsStore.reduceMotion`'s `didSet` pushes changes back in here.
///
/// Zeroing durations is the whole reduce-motion story for the chrome, because the chrome
/// has no scale or gradient effects to guard. Buttons, tabs and rows give press feedback
/// with a tint, never by resizing, and every chrome fill is a flat colour. Adding either
/// back would need a reduce-motion branch of its own, so do not.
enum AnimationSettings {
    /// Written only from the main actor (the settings toggle), read from wherever a view
    /// body runs. A `Bool` word is not worth a lock.
    nonisolated(unsafe) private static var cachedReduceMotion =
        UserDefaults.standard.bool(forKey: SettingsStore.reduceMotionKey)

    static var reduceMotion: Bool { cachedReduceMotion }

    static func reduceMotionDidChange(to value: Bool) {
        cachedReduceMotion = value
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
