import Darwin
import Foundation
import os.signpost

/// Times the launch path, from the kernel's record of when the process started (so dyld
/// and everything before `main` is counted) to the first window's first `onAppear`.
///
/// Two outputs. Signposts on the "Points of Interest" track, for Instruments. And one
/// summary line in the unified log on first paint, so a regression is visible without
/// attaching anything:
///
///     log stream --predicate 'subsystem == "com.aurabrowser.app" and category == "Startup"'
///
/// ponytail: a plain array of marks, no ring buffer and no sampling. It records at most
/// a handful of entries and stops at first paint. Revisit if it ever grows a second use.
enum StartupProfiler {
    private static let logger = AuraLog.category("Startup")

    /// Wall clock at process creation, from `sysctl`. Falls back to "now" if the call
    /// fails, which only makes the reported numbers smaller, never wrong in a way that
    /// hides a regression.
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let started = info.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        )
    }()

    /// Only ever touched on the main thread: every mark below is on the launch path.
    nonisolated(unsafe) private static var marks: [(name: String, ms: Double)] = []
    nonisolated(unsafe) private static var didReport = false

    static func milliseconds(since start: Date = processStart) -> Double {
        Date().timeIntervalSince(start) * 1000
    }

    /// Records how long after process start this point was reached.
    static func mark(_ name: String) {
        guard !didReport else { return }
        marks.append((name, milliseconds()))
        os_signpost(.event, log: AuraLog.pointsOfInterest, name: "startup", "%{public}s", name)
    }

    /// Runs `work`, records how long it took under `name`, and returns its result.
    @discardableResult
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let start = Date()
        let signpost = OSSignpostID(log: AuraLog.pointsOfInterest)
        os_signpost(.begin, log: AuraLog.pointsOfInterest, name: "startupPhase", signpostID: signpost)
        let result = try work()
        os_signpost(
            .end, log: AuraLog.pointsOfInterest, name: "startupPhase", signpostID: signpost,
            "%{public}s", name
        )
        let took = milliseconds(since: start)
        if didReport {
            // Ran after first paint, i.e. it was deliberately deferred. Logged on its
            // own so the cost of the work moved off the launch path stays visible.
            logger.notice("deferred \(name, privacy: .public) \(Int(took.rounded()), privacy: .public) ms")
        } else {
            marks.append(("\(name)(took)", took))
        }
        return result
    }

    /// Call once, from the first window's first `onAppear`. Later windows are ignored.
    static func reportFirstPaint() {
        guard !didReport else { return }
        let total = milliseconds()
        didReport = true
        let breakdown = marks
            .map { "\($0.name) \(Int($0.ms.rounded()))" }
            .joined(separator: ", ")
        logger.notice("first paint \(Int(total.rounded()), privacy: .public) ms [\(breakdown, privacy: .public)]")
        marks.removeAll()
    }
}
