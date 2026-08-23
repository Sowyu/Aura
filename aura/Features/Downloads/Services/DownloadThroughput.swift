import Foundation

/// How fast bytes are arriving across every download in flight, and how long what is
/// left will take at that rate. One number for the whole set, because that is the
/// question a toolbar button can answer in the space it has.
struct DownloadThroughput: Equatable {
    /// Summed across the downloads that are running, smoothed.
    var bytesPerSecond: Double
    /// Nil when nothing is moving, or when a server sent no `Content-Length` and there
    /// is therefore no honest remainder to divide.
    var secondsRemaining: TimeInterval?

    static let idle = DownloadThroughput(bytesPerSecond: 0, secondsRemaining: nil)

    var isIdle: Bool { bytesPerSecond <= 0 }

    /// "1.2 MB/s, 3m left", or just the rate when the sizes are unknown. Empty while
    /// idle, so a caller can branch on the string instead of re-deriving the state.
    var summary: String {
        guard bytesPerSecond > 0 else { return "" }
        let rate = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
        guard let secondsRemaining,
              secondsRemaining.isFinite,
              secondsRemaining > 0,
              let left = Self.formattedTimeRemaining(secondsRemaining)
        else {
            return rate
        }
        return "\(rate), \(left) left"
    }

    /// Two units at most. "4 minutes, 12 seconds, 300 milliseconds" claims a precision
    /// that a smoothed rate does not have.
    static func formattedTimeRemaining(_ seconds: TimeInterval) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds.rounded()))
    }
}

/// Turns the byte counters the progress timers read into a rate.
///
/// A value type with the clock passed in, so the smoothing can be tested without
/// waiting a second for each sample. The manager keeps one of these for the whole set
/// of downloads rather than one per file: the sum of the per-file rates is the same
/// number as the rate of the summed counters, and one estimator means one EMA to keep
/// steady instead of N that each restart whenever a file finishes.
struct DownloadThroughputEstimator {
    /// Weight on the newest sample. One slow second should bend the number, not replace
    /// it, or the badge flickers between 200 KB/s and 8 MB/s on a normal connection.
    static let smoothing = 0.3

    /// Shortest gap between two samples that counts. The progress timers tick at 10 Hz,
    /// and dividing a 100 ms delta by 100 ms turns ordinary jitter into megabytes.
    static let sampleInterval: TimeInterval = 1

    private var rate: Double = 0
    private var lastBytes: Int64?
    private var lastSampledAt: Date?

    init() {}

    /// Feeds one observation of the summed counters. `remainingBytes` is nil when any
    /// file in the set has no known size, since one unknown file makes the whole ETA a
    /// guess. Returns the value to show; it is unchanged between samples, so a caller
    /// that writes it into observable state does not redraw anything at 10 Hz.
    mutating func sample(
        downloadedBytes: Int64,
        remainingBytes: Int64?,
        at now: Date
    ) -> DownloadThroughput {
        guard let lastBytes, let lastSampledAt else {
            self.lastBytes = downloadedBytes
            self.lastSampledAt = now
            return throughput(remainingBytes: remainingBytes)
        }

        let elapsed = now.timeIntervalSince(lastSampledAt)
        guard elapsed >= Self.sampleInterval else {
            return throughput(remainingBytes: remainingBytes)
        }

        let delta = downloadedBytes - lastBytes
        self.lastBytes = downloadedBytes
        self.lastSampledAt = now

        // A download leaving the set takes its bytes out of the sum, so the delta goes
        // negative. That is a new baseline, not a negative transfer rate.
        if delta >= 0 {
            let instant = Double(delta) / elapsed
            rate = rate == 0 ? instant : rate + Self.smoothing * (instant - rate)
        }
        return throughput(remainingBytes: remainingBytes)
    }

    /// Called when the set empties. Without it the next download starts by inheriting
    /// the rate of the one before, which is wrong the moment the two differ.
    mutating func reset() {
        self = DownloadThroughputEstimator()
    }

    private func throughput(remainingBytes: Int64?) -> DownloadThroughput {
        guard rate > 0 else { return .idle }
        return DownloadThroughput(
            bytesPerSecond: rate,
            secondsRemaining: remainingBytes.map { Double(max(0, $0)) / rate }
        )
    }
}
