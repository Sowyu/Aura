import Foundation

/// First-in, first-out admission for downloads waiting on a free slot.
///
/// No WebKit in here on purpose. Holding a transfer back means holding WebKit's
/// destination callback, which is easy to get wrong in a way that leaves a download
/// with nothing on either side of it, so the ordering rules are kept where they can be
/// tested on their own.
struct DownloadQueue {
    /// How many transfers may write to disk at once. Deliberately not a setting: the
    /// number exists so a burst of small files cannot starve a large one, and there is
    /// no answer a user could give that would be better than this one.
    static let concurrencyLimit = 3

    let limit: Int
    private(set) var running: [UUID] = []
    private(set) var waiting: [UUID] = []

    init(limit: Int = DownloadQueue.concurrencyLimit) {
        self.limit = max(1, limit)
    }

    /// True when the download may start now. False means it was parked, and removing
    /// one of the running ids will hand it back in turn.
    @discardableResult
    mutating func admit(_ id: UUID) -> Bool {
        if running.contains(id) { return true }
        if waiting.contains(id) { return false }
        guard running.count < limit else {
            waiting.append(id)
            return false
        }
        running.append(id)
        return true
    }

    /// Starts `id` whether or not a slot is free. A resumed transfer is already on the
    /// wire by the time WebKit hands it back, so there is nothing left to hold; the
    /// count going one over the limit corrects itself as the running ones finish.
    mutating func start(_ id: UUID) {
        waiting.removeAll { $0 == id }
        if !running.contains(id) { running.append(id) }
    }

    /// Drops `id` from wherever it sits, and returns the ids that may start now, in the
    /// order they arrived. Finishing, failing and cancelling are the same event here:
    /// the slot is free either way.
    mutating func remove(_ id: UUID) -> [UUID] {
        running.removeAll { $0 == id }
        waiting.removeAll { $0 == id }

        var promoted: [UUID] = []
        while running.count < limit, !waiting.isEmpty {
            let next = waiting.removeFirst()
            running.append(next)
            promoted.append(next)
        }
        return promoted
    }

    func isWaiting(_ id: UUID) -> Bool {
        waiting.contains(id)
    }
}
