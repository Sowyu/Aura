import AppKit
import Foundation
import UniformTypeIdentifiers

/// What a drop onto Aura's own chrome is carrying.
enum DropPayload: Equatable {
    /// One of Aura's own sidebar rows. The tab drag machinery owns these; every other
    /// drop target has to leave them alone.
    case tabItem
    case files([URL])
    case url(URL)
    /// Text that is not an address. The receiver searches for it.
    case search(String)
    case nothing
}

/// Reads a drag pasteboard into a `DropPayload`.
///
/// Order matters and is the whole point of the type. A tab being dragged out to Finder
/// advertises `public.url`, `public.url-name` and `public.utf8-plain-text` alongside
/// `.auraTabItem` (see `TabDragPasteboardWriter`), so a receiver that reads URLs first
/// treats a row being reordered as a new address to open. `.auraTabItem` is checked
/// before anything else for that reason.
enum DropPayloadReader {
    /// The pure half: everything already pulled off the pasteboard, so the ordering rules
    /// can be exercised without a drag session.
    static func classify(
        hasTabItem: Bool,
        fileURLs: [URL],
        urlString: String?,
        text: String?
    ) -> DropPayload {
        if hasTabItem { return .tabItem }

        let files = fileURLs.filter(\.isFileURL)
        if !files.isEmpty { return .files(files) }

        if let urlString, let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil
        {
            return url.isFileURL ? .files([url]) : .url(url)
        }

        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .nothing }
        // A path or an address typed into another app and dragged over reads as one here
        // too; anything else is a query.
        if let url = constructURL(from: trimmed) {
            return url.isFileURL ? .files([url]) : .url(url)
        }
        return .search(trimmed)
    }

    static func classify(_ pasteboard: NSPasteboard) -> DropPayload {
        let types = pasteboard.types ?? []
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let urlString = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString
        return classify(
            hasTabItem: types.contains(.auraTabItem),
            fileURLs: fileURLs,
            urlString: urlString,
            text: pasteboard.string(forType: .string)
        )
    }

    /// The types a drop receiver registers for. `.fileURL` and `.URL` are the same
    /// pasteboard type family; both are named so a Finder drag and a browser drag are
    /// both offered.
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .auraTabItem]

    /// The same set for SwiftUI's `onDrop`, which speaks `UTType`.
    static let acceptedContentTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText]
}
