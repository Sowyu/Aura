import Foundation
import SwiftData

enum DownloadStatus: String, Codable {
    case pending
    case downloading
    case completed
    case failed
    case cancelled
}

@Model
class Download: ObservableObject, Identifiable {
    var id: UUID
    var originalURL: URL
    var originalURLString: String
    var fileName: String
    var fileSize: Int64
    var downloadedBytes: Int64
    var status: DownloadStatus
    var progress: Double
    var destinationURL: URL?
    var createdAt: Date
    var completedAt: Date?
    var error: String?

    @Transient @Published var isActive: Bool = false
    @Transient @Published var displayProgress: Double = 0.0
    @Transient @Published var displayDownloadedBytes: Int64 = 0
    @Transient @Published var displayFileSize: Int64 = 0

    init(
        id: UUID = UUID(),
        originalURL: URL,
        fileName: String,
        fileSize: Int64 = 0
    ) {
        self.id = id
        self.originalURL = originalURL
        self.originalURLString = originalURL.absoluteString
        self.fileName = fileName
        // `expectedContentLength` is -1 when the server sends no Content-Length.
        self.fileSize = max(0, fileSize)
        self.downloadedBytes = 0
        self.status = .pending
        self.progress = 0.0
        self.createdAt = Date()

        // Initialize published properties
        self.displayFileSize = max(0, fileSize)
        self.displayDownloadedBytes = 0
        self.displayProgress = 0.0
    }

    /// A server that sends no `Content-Length` reports an expected size of `-1`, and
    /// `WKDownload` reports `0` until the first byte arrives. Neither is a size, so the
    /// last known one is kept rather than overwritten with a number the row would render
    /// as "-1 bytes".
    func updateProgress(downloadedBytes: Int64, totalBytes: Int64) {
        self.downloadedBytes = downloadedBytes
        if totalBytes > 0 { self.fileSize = totalBytes }
        self.progress = self.fileSize > 0 ? Double(downloadedBytes) / Double(self.fileSize) : 0.0

        let knownSize = self.fileSize
        let currentProgress = self.progress
        // Update published properties for UI
        DispatchQueue.main.async {
            self.displayDownloadedBytes = downloadedBytes
            self.displayFileSize = knownSize
            self.displayProgress = currentProgress
        }
    }

    func markCompleted(destinationURL: URL) {
        self.status = .completed
        self.progress = 1.0
        self.destinationURL = destinationURL
        self.completedAt = Date()
        self.isActive = false
    }

    func markFailed(error: String) {
        self.status = .failed
        self.error = error
        self.isActive = false
    }

    func markCancelled() {
        self.status = .cancelled
        self.isActive = false
    }

    var formattedFileSize: String {
        return ByteCountFormatter.string(
            fromByteCount: displayFileSize > 0 ? displayFileSize : fileSize,
            countStyle: .file
        )
    }

    var formattedDownloadedSize: String {
        return ByteCountFormatter.string(fromByteCount: displayDownloadedBytes, countStyle: .file)
    }
}
