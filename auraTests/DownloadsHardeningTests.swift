import Foundation
@testable import Aura
import Testing

/// The four rules that make downloads survive daily traffic: how fast they are going,
/// which of them are allowed to go at all, what happens when a name is taken, and what
/// a click on a finished row does.
struct DownloadsHardeningTests {
    // MARK: - Aggregate speed and ETA

    /// A single sample is a baseline, not a rate. Reporting one would make the badge
    /// read "8 MB/s" off the first 100 ms tick of every download.
    @Test func firstSampleReportsNothing() {
        var estimator = DownloadThroughputEstimator()
        let start = Date(timeIntervalSince1970: 0)

        let first = estimator.sample(downloadedBytes: 0, remainingBytes: 1000, at: start)

        #expect(first == .idle)
        #expect(first.summary.isEmpty)
    }

    @Test func rateIsTheSummedDeltaOverTheElapsedTime() {
        var estimator = DownloadThroughputEstimator()
        let start = Date(timeIntervalSince1970: 0)

        _ = estimator.sample(downloadedBytes: 0, remainingBytes: 1000, at: start)
        let second = estimator.sample(
            downloadedBytes: 100,
            remainingBytes: 900,
            at: start.addingTimeInterval(1)
        )

        #expect(second.bytesPerSecond == 100)
        // 900 bytes left at 100 bytes a second.
        #expect(second.secondsRemaining == 9)
    }

    /// The progress timers tick at 10 Hz. Dividing a 100 ms delta by 100 ms turns
    /// ordinary jitter into megabytes, so anything under a second only re-divides the
    /// remainder by the rate already in hand.
    @Test func samplesCloserThanASecondDoNotMoveTheRate() {
        var estimator = DownloadThroughputEstimator()
        let start = Date(timeIntervalSince1970: 0)

        _ = estimator.sample(downloadedBytes: 0, remainingBytes: 1000, at: start)
        _ = estimator.sample(downloadedBytes: 100, remainingBytes: 900, at: start.addingTimeInterval(1))
        let early = estimator.sample(
            downloadedBytes: 150,
            remainingBytes: 850,
            at: start.addingTimeInterval(1.5)
        )

        #expect(early.bytesPerSecond == 100)
        #expect(early.secondsRemaining == 8.5)
    }

    /// One fast second bends the number by 30 percent, it does not replace it. Without
    /// the smoothing the badge flickers between 200 KB/s and 8 MB/s on a normal line.
    @Test func laterSamplesAreSmoothedIntoTheRate() {
        var estimator = DownloadThroughputEstimator()
        let start = Date(timeIntervalSince1970: 0)

        _ = estimator.sample(downloadedBytes: 0, remainingBytes: 1000, at: start)
        _ = estimator.sample(downloadedBytes: 100, remainingBytes: 900, at: start.addingTimeInterval(1))
        let third = estimator.sample(
            downloadedBytes: 300,
            remainingBytes: 700,
            at: start.addingTimeInterval(2)
        )

        // 100 + 0.3 * (200 - 100)
        #expect(abs(third.bytesPerSecond - 130) < 0.000_001)
        #expect(DownloadThroughputEstimator.smoothing == 0.3)
    }

    /// A download finishing takes its bytes out of the sum, so the next delta is
    /// negative. That is a new baseline, and reading it as a rate would show the badge
    /// a negative speed and an ETA in the past.
    @Test func aDownloadLeavingTheSetDoesNotProduceANegativeRate() {
        var estimator = DownloadThroughputEstimator()
        let start = Date(timeIntervalSince1970: 0)

        _ = estimator.sample(downloadedBytes: 0, remainingBytes: 1000, at: start)
        _ = estimator.sample(downloadedBytes: 100, remainingBytes: 900, at: start.addingTimeInterval(1))
        let dropped = estimator.sample(
            downloadedBytes: 20,
            remainingBytes: 300,
            at: start.addingTimeInterval(2)
        )
        #expect(dropped.bytesPerSecond == 100)

        // And the new baseline is the smaller count, not the old one.
        let after = estimator.sample(
            downloadedBytes: 120,
            remainingBytes: 200,
            at: start.addingTimeInterval(3)
        )
        #expect(abs(after.bytesPerSecond - 100) < 0.000_001)
    }

    /// One file with no `Content-Length` makes the whole remainder a guess. The rate is
    /// still real, so it stays; the ETA goes away rather than being quietly wrong.
    @Test func unknownSizesDropTheEtaAndKeepTheRate() {
        var estimator = DownloadThroughputEstimator()
        let start = Date(timeIntervalSince1970: 0)

        _ = estimator.sample(downloadedBytes: 0, remainingBytes: nil, at: start)
        let second = estimator.sample(
            downloadedBytes: 4096,
            remainingBytes: nil,
            at: start.addingTimeInterval(1)
        )

        #expect(second.bytesPerSecond == 4096)
        #expect(second.secondsRemaining == nil)
        #expect(!second.summary.isEmpty)
        #expect(!second.summary.contains("left"))
    }

    /// The next download must not inherit the rate of the one before it.
    @Test func resetClearsTheRate() {
        var estimator = DownloadThroughputEstimator()
        let start = Date(timeIntervalSince1970: 0)

        _ = estimator.sample(downloadedBytes: 0, remainingBytes: 1000, at: start)
        _ = estimator.sample(downloadedBytes: 100, remainingBytes: 900, at: start.addingTimeInterval(1))
        estimator.reset()

        let fresh = estimator.sample(
            downloadedBytes: 0,
            remainingBytes: 500,
            at: start.addingTimeInterval(2)
        )
        #expect(fresh == .idle)
    }

    @Test func idleThroughputHasNothingToSay() {
        #expect(DownloadThroughput.idle.isIdle)
        #expect(DownloadThroughput.idle.summary.isEmpty)
        #expect(DownloadThroughput(bytesPerSecond: 1024, secondsRemaining: 60).summary.contains("/s"))
    }

    /// Averaging the per-file fractions made a 2 GB file at 10 percent and a 2 KB file
    /// at 90 percent read as half done, and the ring jumped backwards whenever a small
    /// file finished.
    @MainActor @Test func aggregateProgressWeightsByBytesNotByFile() {
        let big = Download(originalURL: url("big.iso"), fileName: "big.iso", fileSize: 1000)
        big.downloadedBytes = 100
        let small = Download(originalURL: url("small.txt"), fileName: "small.txt", fileSize: 10)
        small.downloadedBytes = 9

        let weighted = DownloadManager.aggregateProgress(of: [big, small])

        // 109 of 1010 bytes, not the 0.5 the mean of the fractions would give.
        #expect(abs(weighted - 109.0 / 1010.0) < 0.000_001)
    }

    @MainActor @Test func aggregateProgressIsZeroWithNothingToWeigh() {
        #expect(DownloadManager.aggregateProgress(of: []) == 0)

        // A server that sent no Content-Length gives nothing to weigh against.
        let unknown = Download(originalURL: url("stream.bin"), fileName: "stream.bin")
        unknown.downloadedBytes = 5000
        #expect(DownloadManager.aggregateProgress(of: [unknown]) == 0)
    }

    /// `WKDownload` can report more bytes than the response advertised on a chunked
    /// transfer, and a ring trimmed past 1 draws itself twice.
    @MainActor @Test func aggregateProgressNeverExceedsOne() {
        let overrun = Download(originalURL: url("f.zip"), fileName: "f.zip", fileSize: 100)
        overrun.downloadedBytes = 250
        #expect(DownloadManager.aggregateProgress(of: [overrun]) == 1)
    }

    // MARK: - The concurrency cap

    @Test func threeStartAndTheRestWait() {
        var queue = DownloadQueue()
        let ids = (0 ..< 5).map { _ in UUID() }
        var started: [Bool] = []
        for id in ids { started.append(queue.admit(id)) }

        #expect(started == [true, true, true, false, false])
        #expect(queue.running == Array(ids.prefix(3)))
        #expect(queue.waiting == Array(ids.suffix(2)))
        #expect(DownloadQueue.concurrencyLimit == 3)
    }

    /// First in, first out. A queue that hands slots back in dictionary order looks
    /// random to whoever clicked the links in a particular sequence.
    @Test func slotsAreHandedBackInArrivalOrder() {
        var queue = DownloadQueue(limit: 2)
        let (first, second, third, fourth) = (UUID(), UUID(), UUID(), UUID())
        var started: [Bool] = []
        for id in [first, second, third, fourth] { started.append(queue.admit(id)) }
        #expect(started == [true, true, false, false])

        let afterFirst = queue.remove(first)
        let afterSecond = queue.remove(second)

        #expect(afterFirst == [third])
        #expect(afterSecond == [fourth])
        #expect(queue.waiting.isEmpty)
        #expect(queue.running == [third, fourth])
    }

    /// Cancelling something that never started frees nothing and must not promote
    /// anything twice.
    @Test func cancellingAWaitingDownloadJustDropsIt() {
        var queue = DownloadQueue(limit: 1)
        let (running, waiting, behind) = (UUID(), UUID(), UUID())
        var started: [Bool] = []
        for id in [running, waiting, behind] { started.append(queue.admit(id)) }
        #expect(started == [true, false, false])
        #expect(queue.isWaiting(waiting))

        let afterCancel = queue.remove(waiting)
        #expect(afterCancel.isEmpty)
        #expect(!queue.isWaiting(waiting))
        #expect(queue.running == [running])

        let afterFinish = queue.remove(running)
        #expect(afterFinish == [behind])
    }

    /// The destination callback can arrive twice for the same download on a redirect
    /// chain; the second one must not park a download that is already running.
    @Test func admittingTheSameDownloadTwiceIsNotADuplicate() {
        var queue = DownloadQueue(limit: 2)
        let id = UUID()
        let first = queue.admit(id)
        let second = queue.admit(id)

        #expect(first)
        #expect(second)
        #expect(queue.running == [id])
        #expect(queue.waiting.isEmpty)
    }

    /// A resumed transfer is already on the wire by the time WebKit hands it back, so
    /// it takes a slot rather than waiting for one. The count corrects itself as the
    /// running downloads finish.
    @Test func aResumedDownloadTakesASlotEvenWhenFull() {
        var queue = DownloadQueue(limit: 1)
        let (running, queued, resumed) = (UUID(), UUID(), UUID())
        let startedRunning = queue.admit(running)
        let startedQueued = queue.admit(queued)
        #expect(startedRunning)
        #expect(!startedQueued)

        queue.start(resumed)
        #expect(queue.running == [running, resumed])

        // Over the limit, so finishing one promotes nobody yet.
        let afterRunning = queue.remove(running)
        let afterResumed = queue.remove(resumed)
        #expect(afterRunning.isEmpty)
        #expect(afterResumed == [queued])
    }

    // MARK: - Name collisions

    @MainActor @Test func keepBothUsesTheUniquifier() {
        let target = url("report.pdf")

        let resolved = DownloadManager.destinationURL(
            for: .keepBoth,
            target: target,
            uniqueName: { $0.deletingLastPathComponent().appendingPathComponent("report (1).pdf") },
            replaceExisting: { _ in Issue.record("keep both must not delete anything")
                return true
            }
        )

        #expect(resolved?.lastPathComponent == "report (1).pdf")
    }

    @MainActor @Test func replaceWritesOverTheOldFile() {
        let target = url("report.pdf")
        var removed: URL?

        let resolved = DownloadManager.destinationURL(
            for: .replace,
            target: target,
            uniqueName: { _ in Issue.record("replace must not rename")
                return target
            },
            replaceExisting: { removed = $0
                return true
            }
        )

        #expect(resolved == target)
        #expect(removed == target)
    }

    /// WebKit refuses a destination that already exists, so a replace that could not
    /// move the old file aside has to become a keep-both. Failing the download instead
    /// would report an error nobody could act on.
    @MainActor @Test func replaceFallsBackToKeepBothWhenTheOldFileWillNotBudge() {
        let target = url("report.pdf")
        let renamed = url("report (1).pdf")

        let resolved = DownloadManager.destinationURL(
            for: .replace,
            target: target,
            uniqueName: { _ in renamed },
            replaceExisting: { _ in false }
        )

        #expect(resolved == renamed)
    }

    @MainActor @Test func cancelWritesNothingAnywhere() {
        let target = url("report.pdf")

        let resolved = DownloadManager.destinationURL(
            for: .cancel,
            target: target,
            uniqueName: { _ in Issue.record("cancel must not rename")
                return target
            },
            replaceExisting: { _ in Issue.record("cancel must not delete")
                return true
            }
        )

        #expect(resolved == nil)
    }

    // MARK: - Clicking a finished download

    /// The same list the auto-open after a download uses. An archive Aura refused to
    /// open for you is not one it opens because you clicked the row.
    @MainActor @Test func safeTypesOpenAndTheRestGoToFinder() {
        #expect(DownloadManager.openAction(fileExtension: "pdf", isQuarantined: false) == .open)
        #expect(DownloadManager.openAction(fileExtension: "PDF", isQuarantined: false) == .open)
        #expect(DownloadManager.openAction(fileExtension: "zip", isQuarantined: false) == .reveal(.unsafeType))
        #expect(DownloadManager.openAction(fileExtension: "dmg", isQuarantined: false) == .reveal(.unsafeType))
        #expect(DownloadManager.openAction(fileExtension: "svg", isQuarantined: false) == .reveal(.unsafeType))
        #expect(DownloadManager.openAction(fileExtension: "", isQuarantined: false) == .reveal(.unsafeType))

        for ext in DownloadManager.safeExtensions {
            #expect(
                DownloadManager.openAction(fileExtension: ext, isQuarantined: false) == .open,
                "\(ext) is on the safe list but the row would not open it"
            )
        }
    }

    /// Quarantine only changes the wording. A stamped PDF still opens in Preview; a
    /// stamped installer is the case where Finder is the way through Gatekeeper.
    @MainActor @Test func quarantineOnlyChangesTheExplanation() {
        #expect(DownloadManager.openAction(fileExtension: "pdf", isQuarantined: true) == .open)
        #expect(DownloadManager.openAction(fileExtension: "dmg", isQuarantined: true) == .reveal(.quarantined))
        #expect(DownloadRevealReason.quarantined.explanation != DownloadRevealReason.unsafeType.explanation)
        #expect(!DownloadRevealReason.quarantined.explanation.isEmpty)
    }

    @MainActor @Test func aFileNobodyStampedIsNotQuarantined() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-quarantine-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(!DownloadManager.isQuarantined(file))
        #expect(!DownloadManager.isQuarantined(file.appendingPathExtension("missing")))
    }

    // MARK: - Resume against retry

    /// Resuming needs all three at once: WebKit's blob, a page to resume through, and
    /// the partial file's path. Offering Resume without one of them would produce a
    /// button that fails every time it is pressed.
    @MainActor @Test func resumeIsOfferedOnlyWhenAllThreePartsExist() {
        #expect(
            DownloadManager.retryAction(hasResumeData: true, hasPage: true, hasDestination: true) == .resume
        )
        #expect(
            DownloadManager.retryAction(hasResumeData: false, hasPage: true, hasDestination: true) == .retry
        )
        #expect(
            DownloadManager.retryAction(hasResumeData: true, hasPage: false, hasDestination: true) == .retry
        )
        #expect(
            DownloadManager.retryAction(hasResumeData: true, hasPage: true, hasDestination: false) == .retry
        )
    }

    // MARK: - Helpers

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Users/test/Downloads").appendingPathComponent(name)
    }
}
