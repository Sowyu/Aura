import Foundation
import Sparkle
import SwiftSoup

private let logger = AuraLog.category("UpdateDriver")

/// Aura's own front end for Sparkle. Sparkle ships `SPUStandardUserDriver`, which puts
/// its own alerts, its own progress window and its own "Install and Relaunch" button on
/// screen. This replaces it, so an update reaches the user as one button in Aura's
/// chrome and never as a system dialog.
///
/// Two closures Sparkle hands over are held rather than answered on the spot:
/// `updateChoiceReply`, the answer to "an update is available", and whichever
/// cancellation is live. Sparkle keeps the update session open until the reply is used,
/// which is what lets the toolbar button still work minutes after the check that found
/// the update. Everything else is turned into an `UpdateEvent` and handed to
/// `UpdateService`, which reduces it into a phase.
///
/// Sparkle guarantees every method here runs on the main thread.
final class UpdateDriver: NSObject, SPUUserDriver {
    private let onEvent: (UpdateEvent) -> Void

    private var updateChoiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var checkCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    init(onEvent: @escaping (UpdateEvent) -> Void) {
        self.onEvent = onEvent
    }

    // MARK: - Answers Aura gives on the user's behalf

    /// Answers Sparkle's parked "install this?" with yes. False means there was nothing
    /// parked, so the caller has to run a fresh check to get another chance.
    @discardableResult
    func acceptUpdate() -> Bool {
        guard let reply = updateChoiceReply else { return false }
        updateChoiceReply = nil
        reply(.install)
        return true
    }

    /// Ends everything in flight. The pending update is dismissed, not skipped, so the
    /// same version comes back on the next check instead of being hidden for good.
    func cancel() {
        let check = checkCancellation
        let download = downloadCancellation
        let reply = updateChoiceReply
        // Cleared first: a reply can call straight back into `dismissUpdateInstallation`.
        reset()
        check?()
        download?()
        reply?(.dismiss)
    }

    private func reset() {
        checkCancellation = nil
        downloadCancellation = nil
        updateChoiceReply = nil
        expectedLength = 0
        receivedLength = 0
    }

    // MARK: - SPUUserDriver

    /// Never asked. Automatic checks follow Aura's own switch in Settings → About, and
    /// the system profile is not sent, so there is no question left for a dialog.
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        checkCancellation = cancellation
        onEvent(.checkStarted)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        checkCancellation = nil

        // An information-only release has no file to fetch, and Sparkle forbids answering
        // it with `.install`. Since the button's whole job is to answer `.install`, the
        // item is dismissed and the user stays on the version they have.
        guard !appcastItem.isInformationOnlyUpdate else {
            logger.info("Information-only update \(appcastItem.displayVersionString, privacy: .public), dismissed")
            reply(.dismiss)
            onEvent(.dismissed)
            return
        }

        updateChoiceReply = reply
        onEvent(.updateFound(version: appcastItem.displayVersionString, stage: Self.stage(from: state.stage)))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard let text = Self.plainText(from: downloadData) else { return }
        onEvent(.releaseNotes(text))
    }

    /// Not an error the user needs. The version number is what the button is offering;
    /// notes that did not arrive change nothing about installing it.
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        logger.info("Release notes not downloaded: \(error.localizedDescription, privacy: .public)")
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        reset()
        onEvent(.upToDate(checkedAt: Date()))
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        logger.error("Update failed: \(error.localizedDescription, privacy: .public)")
        reset()
        onEvent(.failed(message: error.localizedDescription))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        onEvent(.downloadStarted)
    }

    /// Sparkle may report this more than once for one download, so the bytes already
    /// counted are kept: zeroing them would run the progress backwards mid-download.
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        onEvent(.downloadProgress(fraction: UpdatePhase.fraction(received: receivedLength, expected: expectedLength)))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        onEvent(.downloadProgress(fraction: UpdatePhase.fraction(received: receivedLength, expected: expectedLength)))
    }

    func showDownloadDidStartExtractingUpdate() {
        downloadCancellation = nil
        onEvent(.extractionStarted)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        onEvent(.extractionProgress(fraction: progress))
    }

    /// Yes, without asking. One press of the update button means download, install and
    /// relaunch; the user already said so, and a second confirmation here is the dialog
    /// this driver exists to remove.
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onEvent(.readyToInstall)
        reply(.install)
    }

    /// `retryTerminatingApplication` is deliberately dropped. Sparkle asks the app to quit
    /// and `OraApp` skips its quit confirmation while `UpdateService.isInstalling`, so
    /// nothing left in Aura delays termination. If something ever does, Sparkle still
    /// installs the update the next time the app quits.
    /// ponytail: no retry path; add one if a hung quit is ever observed here.
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        updateChoiceReply = nil
        onEvent(.installing)
    }

    /// Only reached when the updater outlives the swap, which it usually does not: by
    /// this point the old bundle is gone and this process is on its way out.
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        reset()
        onEvent(.dismissed)
    }

    /// A second check while one is already showing. There is no window of Sparkle's to
    /// raise, so this opens the About section, where the same phase is spelled out in
    /// full next to the button.
    func showUpdateInFocus() {
        NotificationCenter.default.post(
            name: .openSettingsTab,
            object: nil,
            userInfo: ["tab": SettingsTab.about.rawValue]
        )
    }

    // MARK: - Helpers

    private static func stage(from stage: SPUUserUpdateStage) -> UpdateStage {
        switch stage {
        case .downloaded: return .downloaded
        case .installing: return .installing
        case .notDownloaded: return .notDownloaded
        @unknown default: return .notDownloaded
        }
    }

    /// Release notes as text. Anything that is not UTF-8 is dropped rather than guessed
    /// at: notes are extra detail next to the version number, so losing them costs the
    /// user nothing.
    private static func plainText(from downloadData: SPUDownloadData) -> String? {
        guard let text = String(data: downloadData.data, encoding: .utf8) else { return nil }
        guard downloadData.mimeType?.localizedCaseInsensitiveContains("html") == true else { return text }
        return (try? SwiftSoup.parse(text).text()) ?? text
    }
}
