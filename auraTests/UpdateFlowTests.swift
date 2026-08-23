import Foundation
@testable import Aura
import Testing

/// The update reducer and its labels, driven the way `UpdateDriver` drives them but with
/// events built by hand. Nothing here touches Sparkle, so the whole flow, including the
/// paths that only happen on a broken network, runs in the test process.
@Suite("In-app updates")
struct UpdateFlowTests {
    /// Every phase an event list walks through, starting from `.idle`.
    private func replay(_ events: [UpdateEvent], from start: UpdatePhase = .idle) -> [UpdatePhase] {
        var phase = start
        return events.map { event in
            phase = phase.reducing(event)
            return phase
        }
    }

    @Test func aSuccessfulUpdateWalksFromCheckingToInstalling() {
        let phases = replay([
            .checkStarted,
            .updateFound(version: "1.0.0", stage: .notDownloaded),
            .downloadStarted,
            .downloadProgress(fraction: 0.25),
            .downloadProgress(fraction: 0.8),
            .extractionStarted,
            .extractionProgress(fraction: 0.5),
            .readyToInstall,
            .installing
        ])

        #expect(phases == [
            .checking,
            .available(version: "1.0.0", notes: nil),
            .downloading(fraction: 0),
            .downloading(fraction: 0.25),
            .downloading(fraction: 0.8),
            .extracting(fraction: 0),
            .extracting(fraction: 0.5),
            .readyToInstall,
            .installing
        ])
    }

    @Test func downloadProgressOnlyEverMovesForward() {
        var fractions: [Double] = []
        var phase = UpdatePhase.downloading(fraction: 0)
        for received in stride(from: UInt64(0), through: 1000, by: 250) {
            phase = phase.reducing(.downloadProgress(
                fraction: UpdatePhase.fraction(received: received, expected: 1000)
            ))
            guard case let .downloading(fraction) = phase else {
                Issue.record("Left the downloading phase at \(received) bytes")
                return
            }
            fractions.append(fraction)
        }
        #expect(fractions == [0, 0.25, 0.5, 0.75, 1])
    }

    /// The expected length is whatever the server claimed, so it can be missing entirely
    /// or shorter than the body that turns up.
    @Test func downloadFractionSurvivesAMissingOrShortContentLength() {
        #expect(UpdatePhase.fraction(received: 500, expected: 0) == 0)
        #expect(UpdatePhase.fraction(received: 0, expected: 0) == 0)
        #expect(UpdatePhase.fraction(received: 2000, expected: 1000) == 1)
    }

    /// Sparkle tears its session down right after reporting an error. The retry button has
    /// to survive that, or it flashes on screen and is gone before it can be pressed.
    @Test func anErrorSurvivesTheDismissalThatFollowsIt() {
        let phases = replay([
            .checkStarted,
            .failed(message: "The feed could not be loaded."),
            .dismissed
        ])
        #expect(phases.last == .failed(message: "The feed could not be loaded."))
    }

    /// Same for a clean result: the About section keeps showing "up to date" after the
    /// session that produced it has ended.
    @Test func aCleanCheckReportsUpToDateAndKeepsIt() {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let phases = replay([.checkStarted, .upToDate(checkedAt: checkedAt), .dismissed])
        #expect(phases == [.checking, .upToDate(checkedAt: checkedAt), .upToDate(checkedAt: checkedAt)])
    }

    /// A dismissal during work in flight is the one case that does clear the phase: a
    /// cancelled check or an abandoned download leaves nothing to show.
    @Test func aDismissalDuringWorkInFlightClearsThePhase() {
        #expect(UpdatePhase.checking.reducing(.dismissed) == .idle)
        #expect(UpdatePhase.downloading(fraction: 0.4).reducing(.dismissed) == .idle)
        #expect(UpdatePhase.extracting(fraction: 0.4).reducing(.dismissed) == .idle)
        #expect(UpdatePhase.available(version: "1.0.0", notes: nil).reducing(.dismissed)
            == .available(version: "1.0.0", notes: nil))
        #expect(UpdatePhase.readyToInstall.reducing(.dismissed) == .readyToInstall)
    }

    /// An update Sparkle already fetched, or already started installing, is past the point
    /// where the button offers to download it.
    @Test func anAlreadyFetchedUpdateSkipsStraightPastAvailable() {
        #expect(UpdatePhase.checking.reducing(.updateFound(version: "1.0.0", stage: .downloaded))
            == .readyToInstall)
        #expect(UpdatePhase.checking.reducing(.updateFound(version: "1.0.0", stage: .installing))
            == .installing)
    }

    @Test func releaseNotesAttachToTheWaitingUpdateAndNothingElse() {
        let waiting = UpdatePhase.available(version: "1.0.0", notes: nil)
        #expect(waiting.reducing(.releaseNotes("Fixes a crash."))
            == .available(version: "1.0.0", notes: "Fixes a crash."))
        #expect(UpdatePhase.downloading(fraction: 0.5).reducing(.releaseNotes("Fixes a crash."))
            == .downloading(fraction: 0.5))
    }

    /// The button is one control with two jobs. Where an update is waiting it installs;
    /// after a failure or a clean check there is no parked reply to answer, so pressing it
    /// runs a fresh check instead.
    @Test func theButtonInstallsOrChecksDependingOnThePhase() {
        #expect(UpdatePhase.failed(message: "offline").buttonAction == .check)
        #expect(UpdatePhase.upToDate(checkedAt: Date()).buttonAction == .check)
        #expect(UpdatePhase.idle.buttonAction == .check)
        #expect(UpdatePhase.available(version: "1.0.0", notes: nil).buttonAction == .install)
        #expect(UpdatePhase.readyToInstall.buttonAction == .install)
        #expect(UpdatePhase.checking.buttonAction == .busy)
        #expect(UpdatePhase.downloading(fraction: 0.5).buttonAction == .busy)
        #expect(UpdatePhase.extracting(fraction: 0.5).buttonAction == .busy)
        #expect(UpdatePhase.installing.buttonAction == .busy)
    }

    @Test func theToolbarPillIsDrawnOnlyWhenThereIsSomethingToSay() {
        #expect(UpdatePhase.idle.toolbarTitle == nil)
        #expect(UpdatePhase.checking.toolbarTitle == nil)
        #expect(UpdatePhase.upToDate(checkedAt: Date()).toolbarTitle == nil)
    }

    @Test func theToolbarLabelFollowsThePhase() {
        #expect(UpdatePhase.available(version: "1.0.0", notes: nil).toolbarTitle == "Update to 1.0.0")
        #expect(UpdatePhase.downloading(fraction: 0.42).toolbarTitle == "Downloading 42%")
        #expect(UpdatePhase.downloading(fraction: 0).toolbarTitle == "Downloading 0%")
        #expect(UpdatePhase.downloading(fraction: 1).toolbarTitle == "Downloading 100%")
        #expect(UpdatePhase.extracting(fraction: 0.5).toolbarTitle == "Preparing…")
        #expect(UpdatePhase.readyToInstall.toolbarTitle == "Restart to update")
        #expect(UpdatePhase.installing.toolbarTitle == "Restarting…")
        #expect(UpdatePhase.failed(message: "offline").toolbarTitle == "Update failed, retry")
    }

    @Test func theAboutButtonKeepsItsCheckForUpdatesTitleWhileIdle() {
        #expect(UpdatePhase.idle.settingsButtonTitle == "Check for Updates")
        #expect(UpdatePhase.upToDate(checkedAt: Date()).settingsButtonTitle == "Check for Updates")
        #expect(UpdatePhase.available(version: "1.0.0", notes: nil).settingsButtonTitle == "Update to 1.0.0")
        #expect(UpdatePhase.failed(message: "offline").settingsButtonTitle == "Retry")
    }

    /// The failure message the driver passes through is what the About section shows, so a
    /// user with a broken feed reads the reason rather than a generic line.
    @Test func theFailureMessageReachesTheStatusLine() {
        #expect(UpdatePhase.failed(message: "The Internet connection is offline.").statusText
            == "The Internet connection is offline.")
        #expect(UpdatePhase.idle.statusText == nil)
    }
}
