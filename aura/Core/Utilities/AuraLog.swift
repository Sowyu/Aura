import OSLog

/// One subsystem for the whole app, one category per area. `log stream --predicate
/// 'subsystem == "com.aurabrowser.app"'` shows everything Aura writes; adding
/// `and category == "Startup"` narrows it to one area.
///
/// Use this instead of `print`: the unified log keeps release builds observable and
/// SwiftLint's `no_print_statements` rule fails the build on the alternative.
enum AuraLog {
    static let subsystem = "com.aurabrowser.app"

    static func category(_ name: String) -> Logger {
        Logger(subsystem: subsystem, category: name)
    }

    /// Instruments' "Points of Interest" track. Same subsystem so the signposts line up
    /// with the log messages around them.
    static let pointsOfInterest = OSLog(subsystem: subsystem, category: .pointsOfInterest)
}
