import Foundation
import SwiftData
import SwiftUI

@Observable
@MainActor
final class DownloadManager {
    var activeDownloads: [Download] = []
    var recentDownloads: [Download] = []
    var isShowingDownloadsHistory = false

    let modelContainer: ModelContainer
    let modelContext: ModelContext
    @ObservationIgnored private var activeDownloadTasks: [UUID: BrowserDownloadTask] = [:]
    // Keeps tasks alive between didStartDownload and cleanup: WKDownload.delegate
    // is weak, so without this the task deallocates before the destination
    // callback and the download never starts.
    @ObservationIgnored private var pendingTasks: [UUID: BrowserDownloadTask] = [:]
    @ObservationIgnored private var taskDownloads: [UUID: Download] = [:]
    @ObservationIgnored private var taskDestinationURLs: [UUID: URL] = [:]
    @ObservationIgnored private var progressTimers: [UUID: Timer] = [:]
    @ObservationIgnored weak var toastManager: ToastManager?

    init(
        modelContainer: ModelContainer,
        modelContext: ModelContext
    ) {
        self.modelContainer = modelContainer
        self.modelContext = modelContext
        loadRecentDownloads()
    }

    /// `@Observable` has no `objectWillChange`. The rows hold their `Download` as a
    /// plain `let`, so a download mutated in place only redraws when the arrays the
    /// list reads are touched. This is the like-for-like replacement.
    private func touchDownloadLists() {
        let active = activeDownloads
        let recent = recentDownloads
        activeDownloads = active
        recentDownloads = recent
    }

    /// Bounded at the store. The unbounded fetch this replaces pulled every download ever
    /// made into memory on each start, complete, fail, cancel and delete, only to throw
    /// all but the newest 50 away.
    /// ponytail: an in-flight download older than the newest 50 drops off the active list.
    /// Fetch it separately if anyone ever starts 50 downloads while one is still running.
    private func loadRecentDownloads() {
        var descriptor = FetchDescriptor<Download>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50

        do {
            let downloads = try modelContext.fetch(descriptor)
            self.recentDownloads = downloads
            self.activeDownloads = downloads.filter { $0.status == .downloading }
        } catch {
            // Failed to load downloads
        }
    }

    func startDownload(
        from downloadTask: BrowserDownloadTask,
        originalURL: URL,
        suggestedFilename: String,
        expectedSize: Int64 = 0
    ) -> Download {
        let download = Download(
            originalURL: originalURL,
            fileName: suggestedFilename,
            fileSize: expectedSize
        )

        download.status = .downloading
        download.isActive = true

        // Save to SwiftData
        modelContext.insert(download)
        do {
            try modelContext.save()
        } catch {
            // Failed to save download
        }

        activeDownloadTasks[download.id] = downloadTask
        activeDownloads.append(download)
        refreshRecentDownloads()

        // Ensure SwiftUI picks up the change when called from WKDownload callbacks
        DispatchQueue.main.async {
            self.touchDownloadLists()
        }

        toastManager?.show("Downloading \(suggestedFilename)", type: .info, icon: .system("arrow.down.circle"))

        return download
    }

    /// No `save()` here on purpose: this runs at 10 Hz per in-flight download, and the
    /// byte counts it writes are re-derived from the task on the next tick anyway. The
    /// completion, failure and cancellation paths persist the final state.
    func updateDownloadProgress(_ download: Download, downloadedBytes: Int64, totalBytes: Int64) {
        download.updateProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes)

        // Trigger UI updates
        DispatchQueue.main.async {
            self.touchDownloadLists()
            download.objectWillChange.send()
        }
    }

    func completeDownload(_ download: Download, destinationURL: URL) {
        download.markCompleted(destinationURL: destinationURL)

        try? modelContext.save()

        activeDownloadTasks.removeValue(forKey: download.id)
        activeDownloads.removeAll { $0.id == download.id }
        refreshRecentDownloads()

        toastManager?.show("Downloaded \(download.fileName)", icon: .system("checkmark.circle"))
        openIfSafe(destinationURL: destinationURL)
    }

    func failDownload(_ download: Download, error: String) {
        download.markFailed(error: error)

        try? modelContext.save()

        activeDownloadTasks.removeValue(forKey: download.id)
        activeDownloads.removeAll { $0.id == download.id }
        refreshRecentDownloads()

        toastManager?.show("Download failed \(download.fileName)", type: .error)
    }

    func cancelDownload(_ download: Download) {
        let fileName = download.fileName
        if let downloadTask = activeDownloadTasks[download.id] {
            downloadTask.cancel()
            cleanupTask(downloadTask.id)
        }

        download.markCancelled()

        try? modelContext.save()

        activeDownloadTasks.removeValue(forKey: download.id)
        activeDownloads.removeAll { $0.id == download.id }
        refreshRecentDownloads()

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
            try? self.modelContext.save()
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

        task.onFail = { [weak self] error in
            guard let self, let download = self.taskDownloads[taskID] else { return }
            self.failDownload(download, error: error.localizedDescription)
            self.cleanupTask(taskID)
        }
    }

    /// Turns the destination rule into a concrete file URL, putting the save panel on
    /// screen first when the user asked to be asked.
    private func resolveDestination(
        for task: BrowserDownloadTask,
        suggestedFilename: String,
        expectedSize: Int64,
        completion: @escaping (URL?) -> Void
    ) {
        switch destination() {
        case let .folder(directory):
            let finalURL = createUniqueFilename(for: directory.appendingPathComponent(suggestedFilename))
            beginDownload(
                task: task,
                suggestedFilename: suggestedFilename,
                finalURL: finalURL,
                expectedSize: expectedSize,
                completion: completion
            )
        case .ask:
            askForDestination(suggestedFilename: suggestedFilename) { [weak self] chosenURL in
                guard let self else { return }
                guard let chosenURL else {
                    completion(nil)
                    self.cleanupTask(task.id)
                    return
                }
                self.beginDownload(
                    task: task,
                    suggestedFilename: chosenURL.lastPathComponent,
                    finalURL: chosenURL,
                    expectedSize: expectedSize,
                    completion: completion
                )
            }
        }
    }

    /// The current destination rule: the folder the user picked, the system Downloads
    /// folder, or a save panel per file.
    func destination() -> DownloadDestination {
        DownloadDestination.resolve(
            askWhereToSave: SettingsStore.shared.askWhereToSaveDownloads,
            chosenFolder: SettingsStore.shared.resolvedDownloadFolder(),
            systemDownloads: getDownloadsDirectory()
        )
    }

    private func beginDownload(
        task: BrowserDownloadTask,
        suggestedFilename: String,
        finalURL: URL,
        expectedSize: Int64,
        completion: @escaping (URL?) -> Void
    ) {
        let download = startDownload(
            from: task,
            originalURL: task.originalURL,
            suggestedFilename: suggestedFilename,
            expectedSize: expectedSize
        )
        taskDownloads[task.id] = download
        taskDestinationURLs[task.id] = finalURL
        startProgressTimer(for: task, download: download, expectedSize: expectedSize)
        completion(finalURL)
    }

    func clearCompletedDownloads() {
        let completedDownloads = recentDownloads.filter { $0.status == .completed }
        for download in completedDownloads {
            modelContext.delete(download)
        }

        try? modelContext.save()
        refreshRecentDownloads()
    }

    func clearNonActiveDownloads() {
        let nonActive = recentDownloads.filter {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }
        for download in nonActive {
            modelContext.delete(download)
        }

        try? modelContext.save()
        refreshRecentDownloads()
    }

    func deleteDownload(_ download: Download) {
        // If it's an active download, cancel it first
        if download.status == .downloading {
            cancelDownload(download)
        }

        modelContext.delete(download)
        try? modelContext.save()
        refreshRecentDownloads()
    }

    func openDownloadInFinder(_ download: Download) {
        guard let destinationURL = download.destinationURL else { return }
        NSWorkspace.shared.selectFile(destinationURL.path, inFileViewerRootedAtPath: "")
    }

    func openFile(_ download: Download) {
        guard let url = download.destinationURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Moves the downloaded file to Trash and removes the entry from history
    func moveToTrash(_ download: Download) {
        if let url = download.destinationURL {
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

    private func refreshRecentDownloads() {
        loadRecentDownloads()
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

    private func startProgressTimer(for task: BrowserDownloadTask, download: Download, expectedSize: Int64) {
        let taskID = task.id
        progressTimers[taskID]?.invalidate()
        progressTimers[taskID] = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let completedBytes = task.progress.completedUnitCount
            let totalBytes = task.progress.totalUnitCount > 0 ? task.progress.totalUnitCount : expectedSize
            Task { @MainActor in
                guard let download = self.taskDownloads[taskID] else { return }
                self.updateDownloadProgress(
                    download,
                    downloadedBytes: completedBytes,
                    totalBytes: totalBytes
                )
            }
        }
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
    }
}
