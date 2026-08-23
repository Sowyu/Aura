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

// MARK: - Opening a finished download

/// Why Finder got the file instead of its default app.
enum DownloadRevealReason: Equatable {
    case unsafeType
    case quarantined

    /// One line, shown as a toast where the file would have opened. A row that silently
    /// does nothing when clicked reads as broken.
    var explanation: String {
        switch self {
        case .unsafeType:
            return "Aura does not open this kind of file for you. It is selected in Finder."
        case .quarantined:
            return "macOS flagged this file as downloaded. Open it from Finder to allow it."
        }
    }
}

/// What clicking a finished download does.
enum DownloadOpenAction: Equatable {
    case open
    case reveal(DownloadRevealReason)
}

extension DownloadManager {
    /// Clicking a row and the auto-open after a download finishes answer to the same
    /// list, so an archive that Aura refused to open for you is not one it opens the
    /// moment you click it.
    ///
    /// Quarantine only decides the wording. A stamped PDF still opens in Preview; a
    /// stamped installer is the case where "reveal it and open it there" is the actual
    /// way through Gatekeeper, so that file gets told so.
    static func openAction(fileExtension: String, isQuarantined: Bool) -> DownloadOpenAction {
        guard safeExtensions.contains(fileExtension.lowercased()) else {
            return .reveal(isQuarantined ? .quarantined : .unsafeType)
        }
        return .open
    }

    /// Whether macOS stamped the file as coming from the internet. Read through
    /// `URLResourceValues` rather than the raw extended attribute: the key is the
    /// documented one, and it comes back nil for a file that was never stamped.
    static func isQuarantined(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]) else {
            return false
        }
        return values.quarantineProperties != nil
    }
}

// MARK: - Name collisions

/// The answer to "that name is taken".
enum DownloadCollisionChoice: Equatable {
    case keepBoth
    case replace
    case cancel
}

// MARK: - Picking up a failed download

/// What a failed row offers.
enum DownloadRetryAction: Equatable {
    /// Carry on from the byte the transfer stopped at.
    case resume
    /// Ask the site for the file again from the start.
    case retry
}

extension DownloadManager {
    /// Resuming needs three things at once: WebKit's resume blob, a live page to resume
    /// through, and the path the partial file is sitting at. Missing any one of them,
    /// starting over is the only honest offer, so the row says Retry instead.
    static func retryAction(
        hasResumeData: Bool,
        hasPage: Bool,
        hasDestination: Bool
    ) -> DownloadRetryAction {
        hasResumeData && hasPage && hasDestination ? .resume : .retry
    }

    /// Which path the bytes go to once the user has answered the collision prompt.
    /// `uniqueName` and `replaceExisting` are passed in so the rule itself never
    /// touches a disk, and so "replace failed" has one place to fall back from.
    static func destinationURL(
        for choice: DownloadCollisionChoice,
        target: URL,
        uniqueName: (URL) -> URL,
        replaceExisting: (URL) -> Bool
    ) -> URL? {
        switch choice {
        case .cancel:
            return nil
        case .keepBoth:
            return uniqueName(target)
        case .replace:
            // WebKit refuses a destination that already exists, so a replace that could
            // not move the old file out of the way has to become a keep-both rather
            // than a download that fails for a reason nobody can see.
            return replaceExisting(target) ? target : uniqueName(target)
        }
    }
}
