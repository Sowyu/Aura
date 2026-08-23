import os.log
import Sparkle
import SwiftUI

private let logger = AuraLog.category("UpdateService")

/// Pure reducer for the outcome of an update check, so the terminal states can be
/// tested without Sparkle. Every outcome clears `isChecking`; the fake 30 second
/// timeout is only a backstop for outcomes Sparkle never reports.
enum UpdateCheckState {
    struct Snapshot: Equatable {
        var isChecking: Bool
        var updateAvailable: Bool
        var resultText: String
    }

    enum Outcome: Equatable {
        case found(version: String)
        case noUpdate(currentVersion: String)
        case failed(reason: String)
    }

    static func apply(_ outcome: Outcome) -> Snapshot {
        switch outcome {
        case let .found(version):
            return Snapshot(isChecking: false, updateAvailable: true, resultText: "Update available: \(version)")
        case let .noUpdate(currentVersion):
            return Snapshot(
                isChecking: false,
                updateAvailable: false,
                resultText: "No updates available (current: \(currentVersion))"
            )
        case let .failed(reason):
            return Snapshot(isChecking: false, updateAvailable: false, resultText: reason)
        }
    }
}

/// One updater for the app, shared by every window. Sparkle wants a single `SPUUpdater`
/// per host bundle, and `start()` does bundle validation and installer-service setup
/// that first paint does not need, so it is deferred: `OraRoot` calls `start()` once the
/// first window is on screen, and the two check entry points start it on demand.
class UpdateService: NSObject, ObservableObject {
    static let shared = UpdateService()
    @Published var canCheckForUpdates = false
    @Published var updateProgress: Double = 0.0
    @Published var isCheckingForUpdates = false
    @Published var updateAvailable = false
    @Published var lastCheckResult: String?
    @Published var lastCheckDate: Date?

    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    private var didStart = false

    /// Idempotent. Safe to call from the deferred launch work and from a check.
    func start() {
        guard !didStart else { return }
        didStart = true
        StartupProfiler.measure("sparkleStart") { setUpUpdater() }
    }

    private func setUpUpdater() {
        let hostBundle = Bundle.main
        let applicationBundle = hostBundle
        let userDriver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        let updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: applicationBundle,
            userDriver: userDriver,
            delegate: self
        )

        self.updater = updater
        self.userDriver = userDriver

        // Start the updater
        do {
            try updater.start()
            self.canCheckForUpdates = true
        } catch {
            logger.error("Failed to start updater: \(error.localizedDescription)")
            self.canCheckForUpdates = false
            self.lastCheckResult = "Updater failed to start: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        start()
        guard let updater, canCheckForUpdates else {
            logger.error(
                "Update checking not available (updater: \(self.updater != nil), canCheck: \(self.canCheckForUpdates))"
            )
            lastCheckResult = "Update checking is not available"
            lastCheckDate = Date()
            isCheckingForUpdates = false
            return
        }

        isCheckingForUpdates = true
        lastCheckResult = "Checking for updates..."
        lastCheckDate = Date()

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.isCheckingForUpdates == true {
                self?.isCheckingForUpdates = false
                self?.lastCheckResult = "Update check timed out"
                self?.lastCheckDate = Date()
            }
        }

        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        start()
        guard let updater, canCheckForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }
}

extension UpdateService: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        return "https://the-aura.github.io/browser/appcast.xml"
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        finish(.found(version: item.displayVersionString))
    }

    /// Sparkle calls this on a clean "you are up to date" result. Without it the
    /// only reset came from `updaterDidNotFindUpdate:error:`, which Sparkle skips
    /// when there is no error, so the UI stayed in "checking" for the full 30
    /// second timeout.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        finish(.noUpdate(currentVersion: Self.currentVersion))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        logger.error("No update found: \(error.localizedDescription)")
        finish(.noUpdate(currentVersion: Self.currentVersion))
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func finish(_ outcome: UpdateCheckState.Outcome) {
        let snapshot = UpdateCheckState.apply(outcome)
        DispatchQueue.main.async {
            self.updateAvailable = snapshot.updateAvailable
            self.isCheckingForUpdates = snapshot.isChecking
            self.lastCheckResult = snapshot.resultText
            self.lastCheckDate = Date()
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        DispatchQueue.main.async {
            self.updateProgress = 0.0
        }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        DispatchQueue.main.async {
            self.updateProgress = 1.0
        }
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        // Update extracted, ready for installation
    }

    func updater(_ updater: SPUUpdater, failedToLoadAppcastWithError error: Error) {
        logger.error("Update error: \(error.localizedDescription)")
        finish(.failed(reason: "Failed to load appcast: \(error.localizedDescription)"))
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        logger.error("Update error: \(error.localizedDescription)")
        let version = item.displayVersionString
        logger.error("Item version: \(version)")
        finish(.failed(reason: "Download failed: \(error.localizedDescription)"))
    }
}
