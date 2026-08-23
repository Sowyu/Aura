import AppKit
import Foundation

/// Everything that turns a local file into a tab: the open panel, the consent step a
/// typed path needs, and the tray row that records it.
///
/// One object for the whole app. Nothing here is per window, and the consent step has to
/// survive the tab it belongs to being switched away from and back.
@Observable
@MainActor
final class FileOpenService {
    static let shared = FileOpenService()

    /// Files waiting on the user's answer, by the tab that asked. Rendered by
    /// `BrowserWebContentView`, which is the view that has a `DialogManager` to ask with.
    private(set) var pendingConsent: [UUID: URL] = [:]

    init() {}

    // MARK: - Open panel

    /// ⌘O. Multiple files, no type filter: a browser opening one kind of file and
    /// refusing another is a rule the user did not ask for, and WebKit already decides
    /// what it can draw.
    func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.message = "Choose files to open in Aura"
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    // MARK: - Grants

    /// Writes down the sandbox grant that came with a file the user handed over: the open
    /// panel, a drop, or Finder opening Aura with it. The grant itself dies with the
    /// process, so this is what lets the tray reopen the file tomorrow.
    func rememberGrants(for urls: [URL]) {
        for url in urls where url.isFileURL {
            FileAccessStore.shared.remember(url)
        }
    }

    /// The gate every route to a local file passes through.
    ///
    /// Returns true when it has taken over, which means a consent prompt is now up and the
    /// caller must not navigate. False means the file is readable and the caller should
    /// carry on: either the sandbox already allows it, or a stored bookmark was opened
    /// just now. Either way a readable file is written into the tray here.
    @discardableResult
    func prepareToOpen(_ url: URL, tabID: UUID, isPrivate: Bool) -> Bool {
        guard url.isFileURL else { return false }
        guard FileAccessStore.shared.needsConsent(for: url) else {
            if !isPrivate { OpenedFileStore.shared.record(url, tabID: tabID) }
            return false
        }
        pendingConsent[tabID] = url
        return true
    }

    func consentRequest(forTab tabID: UUID) -> URL? {
        pendingConsent[tabID]
    }

    func cancelConsent(forTab tabID: UUID) {
        pendingConsent[tabID] = nil
    }

    /// The user said yes to "Aura wants to open <name>".
    ///
    /// Inside the sandbox a dialog cannot grant anything: only Powerbox can, and only
    /// through a panel the user drives. So consent ends in an open panel pointed at the
    /// file's folder. Outside the sandbox there is nothing to ask for and the file is
    /// opened straight away.
    ///
    /// Hands back the URL to load, which is the file the panel returned. A user who
    /// picks a different file in the panel gets that file, not the typed one.
    func confirmConsent(forTab tabID: UUID) -> URL? {
        guard let requested = pendingConsent.removeValue(forKey: tabID) else { return nil }
        return requestAccess(to: requested)
    }

    /// The panel half on its own, for a caller that already has the user's answer: a tray
    /// row whose stored bookmark no longer resolves, for one.
    func requestAccess(to requested: URL) -> URL? {
        guard FileAccessStore.shared.needsConsent(for: requested) else { return requested }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = requested.deletingLastPathComponent()
        panel.nameFieldStringValue = requested.lastPathComponent
        panel.message = "Choose \(requested.lastPathComponent) to let Aura read it."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let chosen = panel.urls.first else { return nil }
        FileAccessStore.shared.remember(chosen)
        return chosen
    }

    /// The sentence the consent dialog leads with.
    static func consentTitle(for url: URL) -> String {
        "Aura wants to open \(url.lastPathComponent)"
    }

    /// Why a second step is being asked for. Only true inside the sandbox, which is the
    /// only place the panel appears.
    static var consentMessage: String {
        FileAccessStore.isSandboxed
            ? "macOS only lets Aura read a file you pick yourself. Confirm the file to open it."
            : "Open this file in the current tab."
    }
}
