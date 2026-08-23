import Foundation
import SwiftData
import SwiftUI

@Observable
@MainActor
final class DownloadManager {
    var activeDownloads: [Download] = []
    var recentDownloads: [Download] = []

    let modelContainer: ModelContainer
    let modelContext: ModelContext
    @ObservationIgnored private var activeDownloadTasks: [UUID: BrowserDownloadTask] = [:]
    // Keeps tasks alive between didStartDownload and cleanup: WKDownload.delegate
    // is weak, so without this the task deallocates before the destination
    // callback and the download never starts. The task holds no page of its own
    // (WKDownload's `webView` is weak), so the stall timeout below is all that is
    // needed to stop a wedged transfer pinning anything.
    @ObservationIgnored private var pendingTasks: [UUID: BrowserDownloadTask] = [:]
    @ObservationIgnored private var taskDownloads: [UUID: Download] = [:]
    @ObservationIgnored private var taskDestinationURLs: [UUID: URL] = [:]
    @ObservationIgnored private var progressTimers: [UUID: Timer] = [:]
    /// Bytes seen on the last tick and when they last moved, per task. A wedged transfer
    /// never calls back, so this is the only thing that can release it.
    @ObservationIgnored private var lastProgress: [UUID: (bytes: Int64, at: Date)] = [:]
    /// WebKit's resume blob for a failed download, keyed by the download's id.
    @ObservationIgnored private var failedResumeData: [UUID: Data] = [:]
    @ObservationIgnored weak var toastManager: ToastManager?
    /// The window's dialog stack, set by `OraRoot`. Used for the name-collision prompt;
    /// nil in a window that has not finished starting, where the old silent-rename
    /// behaviour is the fallback.
    @ObservationIgnored weak var dialogManager: DialogManager?

    /// Which downloads hold one of the three concurrent slots and which are behind them.
    @ObservationIgnored private var queue = DownloadQueue()
    /// Downloads with a destination but no slot. Holding WebKit's destination callback
    /// is what keeps them off the wire: nothing is written until the closure runs.
    /// A window closed with one of these parked never answers its callback, and WebKit
    /// tears the download down with the web view that owned it.
    @ObservationIgnored private var waiting: [UUID: WaitingDownload] = [:]
    @ObservationIgnored private var throughputEstimator = DownloadThroughputEstimator()

    /// Summed rate and ETA across the downloads in flight. Written only when it changes,
    /// which is at most once a second: the progress timers run ten times faster than
    /// that, and writing this is what redraws the downloads button.
    private(set) var throughput = DownloadThroughput.idle

    /// A download parked behind the ones already running.
    private struct WaitingDownload {
        let taskID: UUID
        let finalURL: URL
        let expectedSize: Int64
        let completion: (URL?) -> Void
    }

    init(
        modelContainer: ModelContainer,
        modelContext: ModelContext
    ) {
        self.modelContainer = modelContainer
        self.modelContext = modelContext
        loadRecentDownloads()
    }

    static let recentDownloadsLimit = 50

    /// Bounded at the store. The unbounded fetch this replaces pulled every download ever
    /// made into memory on each start, complete, fail, cancel and delete, only to throw
    /// all but the newest 50 away.
    /// ponytail: an in-flight download older than the newest 50 drops off the active list.
    /// Fetch it separately if anyone ever starts 50 downloads while one is still running.
    private func loadRecentDownloads() {
        var descriptor = FetchDescriptor<Download>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.recentDownloadsLimit

        do {
            let downloads = try modelContext.fetch(descriptor)
            // A row still marked .downloading with no task behind it was left behind by a
            // quit. There is no WKDownload for it any more, so it can never progress or
            // finish; putting it back on the active list only pins a dead row there.
            // The task check matters on the bulk-clear path, where a live download must
            // not be mistaken for a leftover. A row still marked .pending is the same
            // case one step earlier: it was waiting for a slot when the process died.
            let interrupted = downloads.filter {
                ($0.status == .downloading || $0.status == .pending) && activeDownloadTasks[$0.id] == nil
            }
            for download in interrupted {
                download.markFailed(error: Self.interruptedByQuitReason)
            }
            if !interrupted.isEmpty { saveOrLog(modelContext) }
            self.recentDownloads = downloads
            self.activeDownloads = downloads.filter { activeDownloadTasks[$0.id] != nil }
        } catch {
            // Failed to load downloads
        }
    }

    /// Why a download that outlived its process is marked failed.
    static let interruptedByQuitReason = "Interrupted by quit"

    /// `id` and `startsNow` are passed in because the queue has to answer "is there a
    /// slot" before the row exists, and the row's status is what the sidebar renders as
    /// Waiting.
    func startDownload(
        from downloadTask: BrowserDownloadTask,
        originalURL: URL,
        suggestedFilename: String,
        expectedSize: Int64 = 0,
        id: UUID = UUID(),
        startsNow: Bool = true
    ) -> Download {
        let download = Download(
            id: id,
            originalURL: originalURL,
            fileName: suggestedFilename,
            fileSize: expectedSize
        )

        download.status = startsNow ? .downloading : .pending
        download.isActive = startsNow

        // Save to SwiftData
        modelContext.insert(download)
        saveOrLog(modelContext)

        activeDownloadTasks[download.id] = downloadTask
        activeDownloads.append(download)
        // In place, not a refetch: the row that just went in is the one already in hand,
        // and re-reading 50 rows from the store on every start, finish and delete was the
        // whole cost of this list.
        recentDownloads.insert(download, at: 0)
        if recentDownloads.count > Self.recentDownloadsLimit { recentDownloads.removeLast() }

        let message = startsNow ? "Downloading \(suggestedFilename)" : "Queued \(suggestedFilename)"
        toastManager?.show(message, type: .info, icon: .system("arrow.down.circle"))

        return download
    }

    /// No `save()` here on purpose: this runs at 10 Hz per in-flight download, and the
    /// byte counts it writes are re-derived from the task on the next tick anyway. The
    /// completion, failure and cancellation paths persist the final state.
    func updateDownloadProgress(_ download: Download, downloadedBytes: Int64, totalBytes: Int64) {
        // `Download` is a `@Model`, so writing these is what redraws the row. Touching
        // both arrays here as well invalidated every download list ten times a second.
        download.updateProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes)
        refreshThroughput()
    }

    func completeDownload(_ download: Download, destinationURL: URL) {
        download.markCompleted(destinationURL: destinationURL)

        saveOrLog(modelContext)

        activeDownloadTasks.removeValue(forKey: download.id)
        activeDownloads.removeAll { $0.id == download.id }
        releaseSlot(download.id)

        toastManager?.show("Downloaded \(download.fileName)", icon: .system("checkmark.circle"))
        openIfSafe(destinationURL: destinationURL)
    }

    func failDownload(_ download: Download, error: String) {
        download.markFailed(error: error)

        saveOrLog(modelContext)

        activeDownloadTasks.removeValue(forKey: download.id)
        activeDownloads.removeAll { $0.id == download.id }
        releaseSlot(download.id)

        toastManager?.show("Download failed \(download.fileName)", type: .error)
    }

    func cancelDownload(_ download: Download) {
        let fileName = download.fileName
        // A queued download has no transfer to cancel yet. Answering WebKit's parked
        // destination callback with nil is what tears it down; calling `cancel()` on a
        // download that never got a destination leaves the callback outstanding.
        if let parked = waiting.removeValue(forKey: download.id) {
            parked.completion(nil)
            cleanupTask(parked.taskID)
        } else if let downloadTask = activeDownloadTasks[download.id] {
            downloadTask.cancel()
            cleanupTask(downloadTask.id)
        }

        download.markCancelled()

        saveOrLog(modelContext)

        activeDownloadTasks.removeValue(forKey: download.id)
        activeDownloads.removeAll { $0.id == download.id }
        releaseSlot(download.id)

        toastManager?.show("Download cancelled \(fileName)", type: .info, icon: .system("xmark.circle"))
    }

    func handleDownload(_ task: BrowserDownloadTask) {
        // These closures are stored on the task itself; capturing it strongly
        // would make the task retain itself and leak every download.
        let taskID = task.id
        pendingTasks[taskID] = task
        task.onDestinationRequest = { [weak self, weak task] response, suggestedFilename, completion in
            guard let self, let task else {
                completion(nil)
                return
            }
            self.resolveDestination(
                for: task,
                suggestedFilename: suggestedFilename,
                expectedSize: response.expectedContentLength,
                completion: completion
            )
        }

        task.onRedirect = { [weak self] newURL in
            guard let self, let download = self.taskDownloads[taskID] else { return }
            download.originalURL = newURL
            download.originalURLString = newURL.absoluteString
            saveOrLog(self.modelContext)
        }

        task.onFinish = { [weak self] in
            guard let self,
                  let download = self.taskDownloads[taskID],
                  let destinationURL = self.taskDestinationURLs[taskID]
            else {
                return
            }

            self.completeDownload(download, destinationURL: destinationURL)
            self.cleanupTask(taskID)
        }

        task.onFail = { [weak self] error, resumeData in
            guard let self, let download = self.taskDownloads[taskID] else { return }
            // Read back by `resumeDownload(_:using:)`, which is what turns the row's
            // button from Retry into Resume.
            if let resumeData {
                self.failedResumeData[download.id] = resumeData
            }
            self.failDownload(download, error: error.localizedDescription)
            self.cleanupTask(taskID)
        }
    }

    /// Turns the destination rule into a concrete file URL, putting the save panel or
    /// the collision prompt on screen first when one is needed.
    private func resolveDestination(
        for task: BrowserDownloadTask,
        suggestedFilename: String,
        expectedSize: Int64,
        completion: @escaping (URL?) -> Void
    ) {
        switch destination() {
        case let .folder(directory):
            let target = directory.appendingPathComponent(suggestedFilename)
            guard FileManager.default.fileExists(atPath: target.path) else {
                enqueue(
                    task: task,
                    suggestedFilename: suggestedFilename,
                    finalURL: target,
                    expectedSize: expectedSize,
                    completion: completion
                )
                return
            }
            askAboutCollision(fileName: suggestedFilename, folder: directory) { [weak self] choice in
                guard let self else {
                    completion(nil)
                    return
                }
                guard let finalURL = self.resolvedCollisionURL(choice, target: target) else {
                    completion(nil)
                    self.cleanupTask(task.id)
                    return
                }
                self.enqueue(
                    task: task,
                    suggestedFilename: finalURL.lastPathComponent,
                    finalURL: finalURL,
                    expectedSize: expectedSize,
                    completion: completion
                )
            }
        case .ask:
            askForDestination(suggestedFilename: suggestedFilename) { [weak self] chosenURL in
                guard let self else { return }
                guard let chosenURL else {
                    completion(nil)
                    self.cleanupTask(task.id)
                    return
                }
                // The panel does its own replace prompt, but it only returns the URL:
                // the file the user agreed to replace is still there, and WebKit refuses
                // a destination that exists.
                let finalURL = self.removeExistingFile(at: chosenURL)
                    ? chosenURL
                    : self.createUniqueFilename(for: chosenURL)
                self.enqueue(
                    task: task,
                    suggestedFilename: finalURL.lastPathComponent,
                    finalURL: finalURL,
                    expectedSize: expectedSize,
                    completion: completion
                )
            }
        }
    }

    // MARK: - Collisions

    /// Asks what to do about a name that is already taken. Silently renaming is how
    /// people end up with six copies of the same installer and no idea which is current,
    /// so the auto-save path asks like the save panel does.
    ///
    /// Falls back to keeping both when there is no dialog stack to ask in: that is the
    /// old behaviour, and it never loses a file.
    private func askAboutCollision(
        fileName: String,
        folder: URL,
        choose: @escaping (DownloadCollisionChoice) -> Void
    ) {
        guard let dialogManager else {
            choose(.keepBoth)
            return
        }

        final class Answer { var value: DownloadCollisionChoice? }
        let answer = Answer()

        dialogManager.show { id in
            DownloadCollisionDialog(
                fileName: fileName,
                folderName: folder.lastPathComponent
            ) { choice in
                answer.value = choice
                dialogManager.dismiss(id: id)
            }
            // Escape and the backdrop are not answers, but the download is holding
            // WebKit's destination callback and something has to release it.
            .onDisappear { choose(answer.value ?? .cancel) }
        }
    }

    private func resolvedCollisionURL(_ choice: DownloadCollisionChoice, target: URL) -> URL? {
        Self.destinationURL(
            for: choice,
            target: target,
            uniqueName: { [weak self] url in self?.createUniqueFilename(for: url) ?? url },
            replaceExisting: { [weak self] url in self?.removeExistingFile(at: url) ?? false }
        )
    }

    /// Trash rather than delete: replacing is a decision about the new file, not a
    /// licence to destroy the old one. Returns true when the path is clear, which is
    /// also the answer for a file that was never there.
    private func removeExistingFile(at url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return true }

        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            // A file outside the sandbox's reach, or on a volume with no trash.
            Self.log.error(
                "Trashing \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            Self.log.error(
                "Replacing \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    static let log = AuraLog.category("Downloads")

    /// The current destination rule: the folder the user picked, the system Downloads
    /// folder, or a save panel per file.
    func destination() -> DownloadDestination {
        DownloadDestination.resolve(
            askWhereToSave: SettingsStore.shared.askWhereToSaveDownloads,
            chosenFolder: SettingsStore.shared.resolvedDownloadFolder(),
            systemDownloads: getDownloadsDirectory()
        )
    }

    // MARK: - Queue

    /// Creates the row and either starts the transfer or parks it behind the ones
    /// already running. WebKit writes nothing until the destination completion runs, so
    /// holding that closure is the whole mechanism: there is no pause API on `WKDownload`.
    ///
    /// ponytail: a parked download keeps its connection to the server open while it
    /// waits. Nothing in `WKDownloadDelegate` can hold a transfer any later than this,
    /// and three slots means at most a handful of idle sockets. Revisit if servers are
    /// seen dropping queued downloads.
    private func enqueue(
        task: BrowserDownloadTask,
        suggestedFilename: String,
        finalURL: URL,
        expectedSize: Int64,
        completion: @escaping (URL?) -> Void
    ) {
        let id = UUID()
        let startsNow = queue.admit(id)

        let download = startDownload(
            from: task,
            originalURL: task.originalURL,
            suggestedFilename: suggestedFilename,
            expectedSize: expectedSize,
            id: id,
            startsNow: startsNow
        )
        // Recorded at the start, not at the finish: a failed transfer has to remember
        // where its partial file is or there is nothing for Resume to carry on into.
        download.destinationURL = finalURL
        saveOrLog(modelContext)

        taskDownloads[task.id] = download
        taskDestinationURLs[task.id] = finalURL

        guard startsNow else {
            waiting[id] = WaitingDownload(
                taskID: task.id,
                finalURL: finalURL,
                expectedSize: expectedSize,
                completion: completion
            )
            return
        }

        startProgressTimer(for: task, download: download, expectedSize: expectedSize)
        completion(finalURL)
    }

    /// Frees the slot the download held and lets the next one in line off the queue.
    private func releaseSlot(_ id: UUID) {
        for next in queue.remove(id) { startWaiting(next) }
        refreshThroughput()
    }

    private func startWaiting(_ id: UUID) {
        guard let parked = waiting.removeValue(forKey: id),
              let download = taskDownloads[parked.taskID],
              let task = pendingTasks[parked.taskID]
        else {
            return
        }

        // The name was free when this was parked and may not be now, because whatever
        // was running ahead of it could have taken it. WebKit refuses a destination that
        // exists, so the check belongs at the moment the transfer starts. Renaming
        // silently here rather than prompting again: the user already answered a
        // collision prompt for this file, or there was nothing to answer.
        let finalURL = FileManager.default.fileExists(atPath: parked.finalURL.path)
            ? createUniqueFilename(for: parked.finalURL)
            : parked.finalURL

        download.status = .downloading
        download.isActive = true
        download.fileName = finalURL.lastPathComponent
        download.destinationURL = finalURL
        saveOrLog(modelContext)
        taskDestinationURLs[parked.taskID] = finalURL

        startProgressTimer(for: task, download: download, expectedSize: parked.expectedSize)
        parked.completion(finalURL)
    }

    // MARK: - Speed and ETA

    /// Byte-weighted, unlike the mean of the per-file fractions it replaces: a 2 GB file
    /// at 10 percent and a 2 KB file at 90 percent are not half done between them, and
    /// the old ring jumped backwards every time a small file finished.
    static func aggregateProgress(of downloads: [Download]) -> Double {
        let sized = downloads.filter { $0.fileSize > 0 }
        let total = sized.reduce(Int64(0)) { $0 + $1.fileSize }
        guard total > 0 else { return 0 }
        let done = sized.reduce(Int64(0)) { $0 + min($1.downloadedBytes, $1.fileSize) }
        return min(1, Double(done) / Double(total))
    }

    private func refreshThroughput(now: Date = Date()) {
        let running = activeDownloads.filter { $0.status == .downloading }
        guard !running.isEmpty else {
            throughputEstimator.reset()
            if throughput != .idle { throughput = .idle }
            return
        }

        let downloaded = running.reduce(Int64(0)) { $0 + $1.downloadedBytes }
        // One file with no Content-Length makes the whole remainder a guess, so the ETA
        // goes away rather than being quietly wrong.
        let remaining: Int64? = running.allSatisfy { $0.fileSize > 0 }
            ? running.reduce(Int64(0)) { $0 + max(0, $1.fileSize - $1.downloadedBytes) }
            : nil

        let next = throughputEstimator.sample(
            downloadedBytes: downloaded,
            remainingBytes: remaining,
            at: now
        )
        if next != throughput { throughput = next }
    }

    func clearCompletedDownloads() {
        let completedDownloads = recentDownloads.filter { $0.status == .completed }
        for download in completedDownloads {
            modelContext.delete(download)
        }

        saveOrLog(modelContext)
        // Refetched, unlike the single-row paths: a bulk clear can uncover downloads
        // older than the newest 50 this list holds.
        loadRecentDownloads()
    }

    func clearNonActiveDownloads() {
        let nonActive = recentDownloads.filter {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }
        for download in nonActive {
            modelContext.delete(download)
        }

        saveOrLog(modelContext)
        loadRecentDownloads()
    }

    func deleteDownload(_ download: Download) {
        failedResumeData.removeValue(forKey: download.id)
        // If it is still in flight, cancel it first. A queued one counts: it is holding
        // a destination callback WebKit is waiting on.
        if download.status == .downloading || download.status == .pending {
            cancelDownload(download)
        }

        let id = download.id
        modelContext.delete(download)
        saveOrLog(modelContext)
        recentDownloads.removeAll { $0.id == id }
    }

    func openDownloadInFinder(_ download: Download) {
        guard let destinationURL = download.destinationURL else { return }
        NSWorkspace.shared.selectFile(destinationURL.path, inFileViewerRootedAtPath: "")
    }

    func openFile(_ download: Download) {
        guard let url = download.destinationURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Moves the downloaded file to Trash and removes the entry from history.
    ///
    /// Only a finished download has a file to trash: `destinationURL` is set when the
    /// transfer starts, so anything still running would have its half-written file pulled
    /// out from under WebKit. `deleteDownload` cancels that case and leaves the partial
    /// where it is.
    func moveToTrash(_ download: Download) {
        if download.status == .completed, let url = download.destinationURL {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        deleteDownload(download)
    }

    /// Re-opens the original URL in the browser to re-trigger the download
    func retryDownload(_ download: Download) {
        guard let url = URL(string: download.originalURLString) else { return }
        deleteDownload(download)
        if let window = NSApp.keyWindow {
            NotificationCenter.default.post(name: .openURL, object: window, userInfo: ["url": url])
        }
    }

    // MARK: - Resume

    /// Whether WebKit handed back enough to carry this failure on from where it stopped.
    /// Not every failure produces resume data, so the row asks before offering Resume.
    func canResume(_ download: Download) -> Bool {
        failedResumeData[download.id] != nil
    }

    /// Picks a failed transfer up from WebKit's resume blob.
    ///
    /// A page is required because `resumeDownload(fromResumeData:)` is a `WKWebView`
    /// method: the view is not navigated, it is what names the network session, the
    /// cookies and the space's data store the transfer started with. The caller passes
    /// the active tab's page rather than the manager reaching for one, because only the
    /// view layer knows which window asked. With no page, or no partial file to carry
    /// on into, this starts over instead.
    func resumeDownload(_ download: Download, using page: BrowserPage?) {
        let destination = download.destinationURL
        guard let resumeData = failedResumeData[download.id],
              let page,
              let destination
        else {
            retryDownload(download)
            return
        }

        BrowserDownloadTask.resume(
            from: resumeData,
            in: page,
            originalURL: download.originalURL
        ) { [weak self] task in
            guard let self else { return }
            self.handleDownload(task)
            self.adopt(download, resumedBy: task, destination: destination)
        }
    }

    /// Puts a resumed transfer back on the active list under its original row, so the
    /// history keeps one entry per file rather than one per attempt.
    private func adopt(_ download: Download, resumedBy task: BrowserDownloadTask, destination: URL) {
        failedResumeData.removeValue(forKey: download.id)

        download.status = .downloading
        download.isActive = true
        download.error = nil
        saveOrLog(modelContext)

        activeDownloadTasks[download.id] = task
        if !activeDownloads.contains(where: { $0.id == download.id }) {
            activeDownloads.append(download)
        }
        taskDownloads[task.id] = download
        taskDestinationURLs[task.id] = destination
        // Already on the wire by the time WebKit hands it back, so it takes a slot
        // rather than waiting for one.
        queue.start(download.id)

        // WebKit keeps the destination in the resume blob and normally does not ask
        // again. If it does, it gets the same file back: anything else would write the
        // resumed bytes somewhere the row does not point at.
        task.onDestinationRequest = { _, _, completion in completion(destination) }

        startProgressTimer(for: task, download: download, expectedSize: download.fileSize)
    }

    /// Selects the file in Finder and says why it was not opened. Used for the types
    /// `openIfSafe` refuses, so a click on the row always does something visible.
    func revealDownload(_ download: Download, explaining reason: DownloadRevealReason) {
        openDownloadInFinder(download)
        toastManager?.show(reason.explanation, type: .info, icon: .system("folder"))
    }

    /// Helper to get default downloads directory
    func getDownloadsDirectory() -> URL {
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Helper to create unique filename if file already exists
    func createUniqueFilename(for url: URL) -> URL {
        var finalURL = url
        var counter = 1

        while FileManager.default.fileExists(atPath: finalURL.path) {
            let filename = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let directory = url.deletingLastPathComponent()

            let newFilename = ext.isEmpty ? "\(filename) (\(counter))" : "\(filename) (\(counter)).\(ext)"
            finalURL = directory.appendingPathComponent(newFilename)
            counter += 1
        }

        return finalURL
    }

    /// How long a transfer may sit at the same byte count before it counts as wedged.
    static let stallTimeout: TimeInterval = 300
    /// Why a download that stopped moving is marked failed.
    static let stalledReason = "Stalled"

    /// A transfer that has not moved a byte in `timeout` is never going to. WebKit
    /// reports no error for one, so without this its task, its 10 Hz timer and its
    /// entry in `pendingTasks` stayed for the rest of the session.
    static func hasStalled(
        bytes: Int64,
        lastBytes: Int64,
        lastMovedAt: Date,
        now: Date,
        timeout: TimeInterval = DownloadManager.stallTimeout
    ) -> Bool {
        bytes == lastBytes && now.timeIntervalSince(lastMovedAt) >= timeout
    }

    private func startProgressTimer(for task: BrowserDownloadTask, download: Download, expectedSize: Int64) {
        let taskID = task.id
        progressTimers[taskID]?.invalidate()
        lastProgress[taskID] = (bytes: task.progress.completedUnitCount, at: Date())
        progressTimers[taskID] = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let completedBytes = task.progress.completedUnitCount
            let totalBytes = task.progress.totalUnitCount > 0 ? task.progress.totalUnitCount : expectedSize
            Task { @MainActor in
                guard let download = self.taskDownloads[taskID] else { return }
                if self.handleStall(taskID: taskID, download: download, bytes: completedBytes) { return }
                self.updateDownloadProgress(
                    download,
                    downloadedBytes: completedBytes,
                    totalBytes: totalBytes
                )
            }
        }
    }

    /// Returns true when the download was dropped for being stuck.
    private func handleStall(taskID: UUID, download: Download, bytes: Int64) -> Bool {
        let now = Date()
        guard let seen = lastProgress[taskID] else {
            lastProgress[taskID] = (bytes: bytes, at: now)
            return false
        }
        guard Self.hasStalled(bytes: bytes, lastBytes: seen.bytes, lastMovedAt: seen.at, now: now) else {
            if bytes != seen.bytes { lastProgress[taskID] = (bytes: bytes, at: now) }
            return false
        }
        activeDownloadTasks[download.id]?.cancel()
        failDownload(download, error: Self.stalledReason)
        cleanupTask(taskID)
        return true
    }

    /// `cleanupTask` only runs on the completion paths. Closing a window with downloads
    /// in flight left their 10 Hz timers on the run loop for the rest of the session.
    deinit {
        for timer in progressTimers.values { timer.invalidate() }
    }

    private func cleanupTask(_ taskID: UUID) {
        progressTimers[taskID]?.invalidate()
        progressTimers.removeValue(forKey: taskID)
        taskDownloads.removeValue(forKey: taskID)
        taskDestinationURLs.removeValue(forKey: taskID)
        pendingTasks.removeValue(forKey: taskID)
        lastProgress.removeValue(forKey: taskID)
    }
}
