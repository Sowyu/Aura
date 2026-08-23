import Foundation
import SwiftData
import UniformTypeIdentifiers

/// One local file the user opened, and whether it stays in the tray after its tab closes.
///
/// Keyed by the file's path rather than related to `Tab`, for the reason `TabSession` is:
/// a relationship would change the shape of `Tab`, which V2 and V3 of the schema name by
/// its live class. The path is also the identity the user has: opening the same file in
/// a second tab moves the existing row rather than adding a duplicate.
@Model
final class OpenedFile {
    /// The decoded POSIX path, which is what the row is looked up by.
    @Attribute(.unique) var path: String
    /// The `file://` URL as text, percent-encoded, which is what the row shows and what
    /// Copy Path puts on the pasteboard. Stored rather than derived so the string a user
    /// pasted somewhere else still matches the one the tray shows.
    var locationString: String
    var displayName: String
    var openedAt: Date
    /// Pinned rows survive their tab closing, and the sweep that bounds the tray.
    var isPinned: Bool
    /// The tab currently showing the file, when there is one. Closing that tab removes
    /// an unpinned row.
    var tabID: UUID?

    init(
        path: String,
        locationString: String,
        displayName: String,
        openedAt: Date = Date(),
        isPinned: Bool = false,
        tabID: UUID? = nil
    ) {
        self.path = path
        self.locationString = locationString
        self.displayName = displayName
        self.openedAt = openedAt
        self.isPinned = isPinned
        self.tabID = tabID
    }

    /// The file back as a URL. Built from the path, so a row written before the location
    /// string existed still resolves.
    var url: URL {
        URL(fileURLWithPath: path)
    }

    /// The row a file URL makes. `standardizedFileURL` first, so `/tmp/../etc/hosts` and
    /// `/etc/hosts` are one row rather than two.
    static func make(for url: URL, tabID: UUID? = nil, openedAt: Date = Date()) -> OpenedFile {
        let standardized = url.standardizedFileURL
        return OpenedFile(
            path: standardized.path,
            locationString: standardized.absoluteString,
            displayName: standardized.lastPathComponent,
            openedAt: openedAt,
            tabID: tabID
        )
    }
}

extension OpenedFile {
    /// A flat glyph for the file's broad kind. Finder's own icon is a full-colour asset
    /// and reads as a foreign object next to the sidebar's 16pt symbols.
    /// ponytail: the same table as `DownloadHistoryRow.fileSymbol`. Merge the two the next
    /// time either panel grows a third file list.
    var symbolName: String {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}
