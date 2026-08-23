import Foundation

/// What the previous run of the app did, as far as this one can tell.
enum SessionOutcome: Equatable {
    /// No marker either way: a first launch, or a support folder that was cleared.
    case firstRun
    /// The previous run wrote its clean-exit marker on the way out.
    case cleanExit
    /// The previous run started and never got to write one.
    case crashed
}

/// Two empty files in the app's support folder are enough to tell a quit from a crash.
/// A run drops `.session-started` when it begins and replaces it with `.clean-exit` when
/// `applicationWillTerminate` gets its turn; a crash never gets that turn, so the started
/// marker is still lying there at the next launch.
///
/// Both files are read and written here and nowhere else. Guessing wrong is expensive in
/// both directions: a missed crash drops the tabs the crashed run had open, and a false
/// one nags after every ordinary quit.
struct SessionMarker {
    static let cleanExitName = ".clean-exit"
    static let sessionStartedName = ".session-started"

    /// The same folder the store lives in, so a user who moves or clears it moves the
    /// markers with it.
    static let shared = SessionMarker(
        directory: URL.applicationSupportDirectory.appending(path: "Aura")
    )

    let directory: URL

    /// True inside the unit-test host, which is this same app: XCTest kills it instead of
    /// quitting it, so every run after the first would read as a crash.
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The whole state machine, over nothing but "which files are there".
    static func verdict(hasCleanExit: Bool, hasSessionStarted: Bool) -> SessionOutcome {
        if hasCleanExit { return .cleanExit }
        return hasSessionStarted ? .crashed : .firstRun
    }

    /// Reads the previous run's verdict and marks this one as started. Call once.
    @discardableResult
    func beginSession() -> SessionOutcome {
        let manager = FileManager.default
        let cleanExit = directory.appending(path: Self.cleanExitName)
        let started = directory.appending(path: Self.sessionStartedName)
        let outcome = Self.verdict(
            hasCleanExit: manager.fileExists(atPath: cleanExit.path),
            hasSessionStarted: manager.fileExists(atPath: started.path)
        )
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? manager.removeItem(at: cleanExit)
        // Empty on purpose: the file being there is the entire record.
        manager.createFile(atPath: started.path, contents: nil)
        return outcome
    }

    /// The quit half. Written before the process goes, so the next launch sees a clean
    /// exit rather than the started marker.
    func endSession() {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        manager.createFile(atPath: directory.appending(path: Self.cleanExitName).path, contents: nil)
        try? manager.removeItem(at: directory.appending(path: Self.sessionStartedName))
    }
}
