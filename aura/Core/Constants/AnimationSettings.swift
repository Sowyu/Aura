import SwiftUI
import os

/// Chrome animation helpers. SettingsStore updates the cached app preference;
/// readers and writers share a lock because they can run on different threads.
enum AnimationSettings {
    private static let cachedReduceMotion = OSAllocatedUnfairLock(
        initialState: UserDefaults.standard.bool(forKey: SettingsStore.reduceMotionKey) || NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion
    )

    static var reduceMotion: Bool { cachedReduceMotion.withLock { $0 } }

    static func reduceMotionDidChange(to value: Bool) {
        let effective = value || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cachedReduceMotion.withLock { $0 = effective }
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
