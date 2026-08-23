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
class Download: Identifiable {
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

    @Transient var isActive: Bool = false

    /// The row reads these. They were `@Published` mirrors kept in step from a main-queue
    /// hop, which nothing subscribed to: the row holds its download as a plain `let`, so
    /// only the manager touching its arrays redrew it. `@Model` is already observable, so
    /// reading the stored value straight through is what makes a progress tick land.
    var displayProgress: Double { progress }
    var displayDownloadedBytes: Int64 { downloadedBytes }
    var displayFileSize: Int64 { fileSize }

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
    }

    /// A server that sends no `Content-Length` reports an expected size of `-1`, and
    /// `WKDownload` reports `0` until the first byte arrives. Neither is a size, so the
    /// last known one is kept rather than overwritten with a number the row would render
    /// as "-1 bytes".
    func updateProgress(downloadedBytes: Int64, totalBytes: Int64) {
        self.downloadedBytes = downloadedBytes
        if totalBytes > 0 { self.fileSize = totalBytes }
        self.progress = self.fileSize > 0 ? Double(downloadedBytes) / Double(self.fileSize) : 0.0
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
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedDownloadedSize: String {
        return ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }
}
