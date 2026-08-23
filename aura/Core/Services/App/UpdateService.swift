import Foundation
import Sparkle
import SwiftUI

private let logger = AuraLog.category("UpdateService")

/// Where the running copy is in an update, from the user's side. This is the only thing
/// about Sparkle the UI ever sees: the toolbar pill and the About section both render
/// this one value, and the tests drive it without a Sparkle object in sight.
enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    /// `notes` arrives later than the version. Sparkle downloads linked release notes
    /// after it has already announced the update.
    case available(version: String, notes: String?)
    case downloading(fraction: Double)
    case extracting(fraction: Double)
    /// Downloaded and unpacked. Aura quits and comes back on the new version from here.
    case readyToInstall
    case installing
    case failed(message: String)
}

/// How far along Sparkle already is the first time it mentions an update. Mirrors
/// `SPUUserUpdateStage`, so the reducer does not import Sparkle to read it.
enum UpdateStage: Equatable {
    case notDownloaded
    case downloaded
    case installing
}

/// One case per driver callback that changes what the user sees. Plain values, so a test
/// can replay a whole update by hand.
enum UpdateEvent: Equatable {
    case checkStarted
    case updateFound(version: String, stage: UpdateStage)
    case releaseNotes(String)
    case upToDate(checkedAt: Date)
    case downloadStarted
    case downloadProgress(fraction: Double)
    case extractionStarted
    case extractionProgress(fraction: Double)
    case readyToInstall
    case installing
    case failed(message: String)
    case dismissed
}

extension UpdatePhase {
    /// The reducer. Pure `(phase, event) -> phase`: `UpdateDriver` feeds it every Sparkle
    /// callback and `UpdateService` publishes the result.
    func reducing(_ event: UpdateEvent) -> UpdatePhase {
        switch event {
        case .checkStarted:
            return .checking

        case let .updateFound(version, stage):
            switch stage {
            case .notDownloaded: return .available(version: version, notes: nil)
            // A copy already on disk from an earlier session, or one Sparkle picked up
            // mid-install. Neither is still waiting to be fetched.
            case .downloaded: return .readyToInstall
            case .installing: return .installing
            }

        case let .releaseNotes(text):
            // Notes are only worth keeping while the update is still waiting on the user.
            guard case let .available(version, _) = self else { return self }
            return .available(version: version, notes: text)

        case let .upToDate(checkedAt):
            return .upToDate(checkedAt: checkedAt)

        case .downloadStarted:
            return .downloading(fraction: 0)

        case let .downloadProgress(fraction):
            return .downloading(fraction: fraction)

        case .extractionStarted:
            return .extracting(fraction: 0)

        case let .extractionProgress(fraction):
            return .extracting(fraction: fraction)

        case .readyToInstall:
            return .readyToInstall

        case .installing:
            return .installing

        case let .failed(message):
            return .failed(message: message)

        case .dismissed:
            // Sparkle tears its session down after every outcome, the good ones included,
            // so this clears only the phases that mean work in flight. Resetting `.failed`
            // or `.upToDate` here would take the retry button and the last result off
            // screen the instant they appeared.
            switch self {
            case .checking, .downloading, .extracting: return .idle
            default: return self
            }
        }
    }

    /// Download progress from Sparkle's two byte counts. The expected length is whatever
    /// the server claimed, so it can be zero, or short of the body that actually arrives.
    static func fraction(received: UInt64, expected: UInt64) -> Double {
        guard expected > 0 else { return 0 }
        return min(1, Double(received) / Double(expected))
    }
}

// MARK: - Labels

extension UpdatePhase {
    /// What the one update button does here. `.failed` and `.upToDate` check again rather
    /// than install: there is no parked reply left to answer, and a user pressing "Retry"
    /// means run the whole thing again.
    enum ButtonAction: Equatable {
        case check
        case install
        /// Sparkle is working. The button stays on screen and takes no clicks.
        case busy
    }

    var buttonAction: ButtonAction {
        switch self {
        case .available, .readyToInstall: return .install
        case .idle, .upToDate, .failed: return .check
        case .checking, .downloading, .extracting, .installing: return .busy
        }
    }

    /// Title of the toolbar pill. Nil in the phases where the pill is not drawn: there is
    /// nothing to say about an update nobody has found yet.
    var toolbarTitle: String? {
        switch self {
        case .idle, .checking, .upToDate: return nil
        case let .available(version, _): return "Update to \(version)"
        case let .downloading(fraction): return "Downloading \(Self.percent(fraction))%"
        case .extracting: return "Preparing…"
        case .readyToInstall: return "Restart to update"
        case .installing: return "Restarting…"
        case .failed: return "Update failed, retry"
        }
    }

    /// Title of the one button in Settings → About, which is always on screen.
    var settingsButtonTitle: String {
        switch self {
        case .idle, .upToDate: return "Check for Updates"
        case .checking: return "Checking…"
        case .failed: return "Retry"
        case .available, .downloading, .extracting, .readyToInstall, .installing:
            return toolbarTitle ?? "Check for Updates"
        }
    }

    /// The status line under that button. Nil before the first check of the session.
    var statusText: String? {
        switch self {
        case .idle: return nil
        case .checking: return "Checking for updates…"
        case .upToDate: return "Aura is up to date."
        case let .available(version, _): return "Version \(version) is available."
        case let .downloading(fraction): return "Downloading, \(Self.percent(fraction))%."
        case .extracting: return "Preparing the update…"
        case .readyToInstall: return "Ready to install. Aura restarts to finish."
        case .installing: return "Installing. Aura restarts in a moment."
        case let .failed(message): return message
        }
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * 100).rounded())
    }
}

// MARK: - Service

/// One updater for the app, shared by every window. Sparkle wants a single `SPUUpdater`
/// per host bundle, and `start()` does bundle validation and installer-service setup
/// that first paint does not need, so it is deferred: `OraRoot` calls `start()` once the
/// first window is on screen, and the two check entry points start it on demand.
///
/// The user driver is Aura's own (`UpdateDriver`), not `SPUStandardUserDriver`, so an
/// update never arrives as a system alert. It arrives as `phase`, which the toolbar
/// draws as one button.
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    /// Six hours between scheduled checks.
    static let checkInterval: TimeInterval = 6 * 60 * 60

    /// Written only by `handle(_:)`, which Sparkle only ever reaches on the main thread.
    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheckDate: Date?

    private var updater: SPUUpdater?
    private var driver: UpdateDriver?
    private var didStart = false

    private init() {}

    /// True while Sparkle is quitting the app to swap the bundle in. `OraApp` reads it to
    /// skip the quit confirmation: the user agreed to the restart by pressing the update
    /// button, and a dialog there stops an install that is already under way.
    var isInstalling: Bool { phase == .installing }

    /// Idempotent. Safe to call from the deferred launch work and from a check.
    func start() {
        guard !didStart else { return }
        didStart = true
        StartupProfiler.measure("sparkleStart") { setUpUpdater() }
    }

    private func setUpUpdater() {
        let hostBundle = Bundle.main
        let driver = UpdateDriver { [weak self] event in self?.handle(event) }
        let updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: driver,
            // The feed URL, the public key and the version all live in Info.plist, where
            // the release scripts write them. A delegate that returns a feed URL of its
            // own would shadow that file and quietly pin the app to a stale address.
            delegate: nil
        )

        self.updater = updater
        self.driver = driver

        do {
            try updater.start()
            canCheckForUpdates = true
        } catch {
            // Logged, not published. A bundle Sparkle refuses to update is not something
            // the user can retry, and a permanent "Update failed" pill in the toolbar of
            // every unsigned build would be noise. A check they ask for still reports it.
            logger.error("Updater failed to start: \(error.localizedDescription)")
            canCheckForUpdates = false
            return
        }

        applyAutomaticChecks(SettingsStore.shared.autoUpdateEnabled)
        updater.updateCheckInterval = Self.checkInterval
        // The button is the consent. Nothing is fetched until the user presses it, so a
        // download never starts behind a metered connection on its own.
        updater.automaticallyDownloadsUpdates = false
    }

    /// Follows the "Check for updates automatically" switch in Settings → About. Sparkle
    /// keeps its own schedule, so the switch has to reach it or the app keeps checking
    /// every six hours after the user turned checking off.
    func applyAutomaticChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        start()
        guard let updater, canCheckForUpdates else {
            logger.error("Update checking is not available")
            phase = .failed(message: "Update checking is not available.")
            return
        }
        lastCheckDate = Date()
        // The phase is not set here. Sparkle answers with `showUserInitiatedUpdateCheck`,
        // and when a session is already in flight it answers with `showUpdateInFocus`
        // instead, which must not throw away an update that is already on screen.
        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        start()
        guard let updater, canCheckForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }

    /// What the toolbar pill and the About button both call. Where an update is waiting,
    /// this is the yes Sparkle is blocked on, and it runs the download, the install and
    /// the relaunch without another prompt. Where there is nothing to install it starts a
    /// check instead, so "Retry" after a failure and "Check for Updates" when idle both
    /// land here.
    func installAvailableUpdate() {
        switch phase.buttonAction {
        case .install:
            // A false answer means the session Sparkle offered is gone, which leaves
            // nothing to accept. Asking again is the only way back to an installable update.
            if driver?.acceptUpdate() != true { checkForUpdates() }
        case .check:
            checkForUpdates()
        case .busy:
            break
        }
    }

    /// Drops whatever Sparkle has in flight: a running check, a running download, or an
    /// update the user never answered. The update is dismissed rather than skipped, so
    /// the same version is offered again on the next check.
    func cancel() {
        driver?.cancel()
        phase = .idle
    }

    /// The one place `phase` changes. Sparkle calls the driver on the main thread, so this
    /// runs there too, which is what keeps the `@Published` writes off a background queue.
    private func handle(_ event: UpdateEvent) {
        phase = phase.reducing(event)
        switch event {
        case let .upToDate(checkedAt): lastCheckDate = checkedAt
        case .updateFound, .failed: lastCheckDate = Date()
        default: break
        }
    }
}
