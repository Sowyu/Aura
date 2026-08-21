import AppKit
import Foundation

/// Where a download is written. Decided before the save panel or the file system is
/// touched, so the rule itself is testable without either.
enum DownloadDestination: Equatable {
    case ask
    case folder(URL)

    static func resolve(
        askWhereToSave: Bool,
        chosenFolder: URL?,
        systemDownloads: URL
    ) -> DownloadDestination {
        if askWhereToSave { return .ask }
        return .folder(chosenFolder ?? systemDownloads)
    }
}

@MainActor
extension DownloadManager {
    /// Async on purpose: `runModal` here would block WebKit's download delegate while
    /// the panel is up.
    func askForDestination(suggestedFilename: String, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = SettingsStore.shared.resolvedDownloadFolder() ?? getDownloadsDirectory()
        panel.canCreateDirectories = true
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    /// Document types that cannot run code on open. Archives and disk images are left
    /// out on purpose: they are the usual carrier for something that can. So is SVG,
    /// which looks like an image but is a document that can carry `<script>`, and whose
    /// default handler on most Macs is a browser.
    static let safeExtensions: Set<String> = [
        "pdf", "txt", "rtf", "csv", "json", "xml", "md",
        "png", "jpg", "jpeg", "gif", "webp", "heic",
        "mp3", "m4a", "wav", "flac", "mp4", "m4v", "mov"
    ]

    func openIfSafe(destinationURL: URL) {
        guard SettingsStore.shared.openSafeDownloads else { return }
        guard Self.safeExtensions.contains(destinationURL.pathExtension.lowercased()) else { return }
        NSWorkspace.shared.open(destinationURL)
    }
}
