import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The file panels every import and export here goes through.
///
/// Never a hard-coded path. Aura is sandboxed, so the only read it is allowed to make is
/// one the user pointed at: the open panel runs outside the app and hands back a URL the
/// sandbox has already granted. That matters most for Safari, whose `Bookmarks.plist`
/// sits behind full-disk access as well as the sandbox, so `directoryURL` is a hint that
/// opens the panel in the right place and nothing more. If the read still fails, the
/// caller says so rather than showing an empty list.
@MainActor
enum DataPortabilityPanels {
    /// `FileManager.homeDirectoryForCurrentUser` answers with the sandbox container, so
    /// the panel would open inside Aura's own data. The passwd entry is the real home,
    /// which is where the user's Safari folder is. Same trick `LegacyDataMigrator` uses
    /// to find the pre-rename container.
    static var realHomeDirectory: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: directory))
    }

    /// Returns nil when the user cancelled, which is not an error.
    static func read(_ format: BookmarkImportFormat) async throws -> Data? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"

        switch format {
        case .netscapeHTML:
            panel.allowedContentTypes = [.html]
            panel.message = "Choose the bookmarks HTML file your browser exported."
        case .safariPropertyList:
            panel.allowedContentTypes = [.propertyList]
            panel.directoryURL = realHomeDirectory.appending(path: "Library/Safari")
            panel.message = "Choose Bookmarks.plist in your Safari folder."
        }

        guard let url = await choose(panel) else { return nil }
        return try Data(contentsOf: url)
    }

    static func readSettingsFile() async throws -> Data? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.message = "Choose an Aura settings file."
        guard let url = await choose(panel) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Every panel here runs through `begin`, never `runModal`. A modal run loop freezes
    /// every window in the app, including a web process parked on a synchronous ask, and
    /// the password export holds the plain-text CSV in memory for as long as it spins.
    /// `NSOpenPanel` is an `NSSavePanel`, so one helper covers both.
    private static func choose(_ panel: NSSavePanel) async -> URL? {
        await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    /// Writes `data` where the user picks. `isSensitive` narrows the file to the owner
    /// before anything else on the Mac can read it, which is the difference between a
    /// password export and a bookmarks file.
    @discardableResult
    static func write(
        _ data: Data,
        suggestedName: String,
        contentType: UTType,
        isSensitive: Bool = false
    ) async throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.isExtensionHidden = false
        guard let url = await choose(panel) else { return false }
        guard isSensitive else {
            try data.write(to: url, options: [.atomic])
            return true
        }
        // Created with the mode it needs rather than written and then narrowed: an
        // atomic write publishes the temp file under the default umask first, and a
        // world-readable plain-text password file, however briefly, is the one thing
        // this path exists to avoid.
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return true
    }
}

// MARK: - Bookmarks

/// Import and export rows for the bookmark manager.
///
/// One card rather than one per browser: the Netscape HTML export is the same file
/// whichever of Chrome, Firefox or Edge wrote it, and offering three buttons that run
/// identical code would only make the user guess which one their file matches.
struct BookmarkPortabilityCard: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(DialogManager.self) private var dialogManager
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsCard(
            header: "Import and export",
            description: "Folders arrive one level deep, the way Aura stores them. "
                + "Pages already saved here are left alone."
        ) {
            HStack(spacing: 8) {
                OraButton(
                    label: "Import HTML…",
                    variant: .secondary,
                    size: .sm,
                    leadingIcon: "square.and.arrow.down"
                ) {
                    Task { await BookmarkImportAction.run(.netscapeHTML, store: store, dialogManager: dialogManager) }
                }
                OraButton(
                    label: "Import from Safari…",
                    variant: .secondary,
                    size: .sm,
                    leadingIcon: "square.and.arrow.down"
                ) {
                    Task {
                        await BookmarkImportAction.run(
                            .safariPropertyList, store: store, dialogManager: dialogManager
                        )
                    }
                }
                Spacer()
                OraButton(
                    label: "Export…",
                    variant: .secondary,
                    size: .sm,
                    leadingIcon: "square.and.arrow.up"
                ) {
                    Task { await BookmarkImportAction.export(store: store) }
                }
            }

            Text("Chrome, Firefox and Edge all write the same bookmarks HTML file. "
                + "Safari keeps its bookmarks in Bookmarks.plist inside your Safari folder.")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The import and export the bookmark card and the first-run card share.
@MainActor
enum BookmarkImportAction {
    static func run(_ format: BookmarkImportFormat, store: BookmarkStore, dialogManager: DialogManager) async {
        do {
            guard let data = try await DataPortabilityPanels.read(format) else { return }
            let parsed = format.parse(data)
            guard !parsed.isEmpty else {
                ToastManager.shared.show("No bookmarks in that file.", type: .error)
                return
            }
            let summary = BookmarkPortability.apply(parsed, to: store)
            report(summary)
        } catch {
            // The read is what fails here, and its reason is the useful part: a Safari
            // folder the panel could not hand over reads differently from a deleted file.
            dialogManager.confirm(
                title: "Could not read that file",
                message: error.localizedDescription,
                confirmLabel: "OK",
                onConfirm: {}
            )
        }
    }

    static func export(store: BookmarkStore) async {
        let rows = BookmarkPortability.exportable(from: store)
        guard !rows.isEmpty else {
            ToastManager.shared.show("There are no bookmarks to export.", type: .info)
            return
        }
        do {
            let html = NetscapeBookmarks.export(rows)
            let written = try await DataPortabilityPanels.write(
                Data(html.utf8),
                suggestedName: "aura-bookmarks.html",
                contentType: .html
            )
            if written {
                ToastManager.shared.show("Exported \(rows.count) bookmark\(rows.count == 1 ? "" : "s").")
            }
        } catch {
            ToastManager.shared.show("Export failed: \(error.localizedDescription)", type: .error)
        }
    }

    private static func report(_ summary: BookmarkPortability.ImportSummary) {
        guard summary.added > 0 else {
            ToastManager.shared.show("Everything in that file was already saved.", type: .info)
            return
        }
        var message = "Imported \(summary.added) bookmark\(summary.added == 1 ? "" : "s")"
        if summary.foldersCreated > 0 {
            message += " into \(summary.foldersCreated) new folder\(summary.foldersCreated == 1 ? "" : "s")"
        }
        if summary.skipped > 0 {
            message += ", skipped \(summary.skipped) already saved"
        }
        ToastManager.shared.show(message + ".")
    }
}

// MARK: - Passwords

/// The plain-text password escape hatch, behind a warning and an authentication.
///
/// Three things have to happen before a secret reaches disk, in this order: the user
/// reads what the file is and confirms it, macOS authenticates them, and only then does
/// the save panel open. Nothing is read out of the keychain until the authentication
/// comes back true, and no path here logs, toasts or copies a password: the only place
/// one exists is the string handed straight to `Data`.
struct PasswordExportCard: View {
    @Environment(DialogManager.self) private var dialogManager
    @Environment(\.theme) private var theme

    @StateObject private var passwords = PasswordManagerService.shared
    @State private var isExporting = false

    private static let warningTitle = "Export passwords as plain text?"
    private static let warningMessage = """
    The file Aura writes holds every saved password in readable text. Anyone who opens \
    it has your accounts, and so does anything that syncs the folder you save it to. \
    Delete the file as soon as the other password manager has read it.
    """

    var body: some View {
        SettingsCard(
            header: "Export passwords",
            description: "A CSV in Chrome's column order, which is what password managers read."
        ) {
            HStack {
                Text(passwords.entries.isEmpty
                    ? "No saved passwords to export."
                    : "\(passwords.entries.count) saved password\(passwords.entries.count == 1 ? "" : "s").")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.mutedForeground)
                Spacer()
                OraButton(
                    label: "Export…",
                    variant: .destructive,
                    size: .sm,
                    isDisabled: passwords.entries.isEmpty || isExporting,
                    leadingIcon: "square.and.arrow.up"
                ) {
                    dialogManager.confirm(
                        title: Self.warningTitle,
                        message: Self.warningMessage,
                        confirmLabel: "Continue",
                        variant: .destructive,
                        onConfirm: { Task { await authenticateAndExport() } }
                    )
                }
            }

            Text("Aura asks for your Mac login or Touch ID first. The file is written "
                + "readable by you only, but nothing stops it being copied afterwards.")
                .font(.system(size: 11))
                .foregroundStyle(theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func authenticateAndExport() async {
        isExporting = true
        defer { isExporting = false }

        guard await passwords.authenticate(reason: "export your saved passwords as plain text") else {
            ToastManager.shared.show("Export cancelled: not authenticated.", type: .error)
            return
        }

        var rows: [PasswordCSVExport.Row] = []
        var failed = 0
        for entry in passwords.entries {
            guard let password = try? passwords.revealPassword(for: entry) else {
                failed += 1
                continue
            }
            rows.append(PasswordCSVExport.row(
                host: entry.host,
                origin: entry.origin,
                username: entry.username,
                password: password
            ))
        }

        guard !rows.isEmpty else {
            ToastManager.shared.show("No passwords could be read from the keychain.", type: .error)
            return
        }

        do {
            let written = try await DataPortabilityPanels.write(
                Data(PasswordCSVExport.csv(rows).utf8),
                suggestedName: "aura-passwords.csv",
                contentType: .commaSeparatedText,
                isSensitive: true
            )
            guard written else { return }
            // A count, never a value. The error branch below carries the system's own
            // message, which is about the file and not about what is in it.
            var message = "Exported \(rows.count) password\(rows.count == 1 ? "" : "s")."
            if failed > 0 {
                message += " \(failed) could not be read."
            }
            ToastManager.shared.show(message)
        } catch {
            ToastManager.shared.show("Export failed: \(error.localizedDescription)", type: .error)
        }
    }
}

// MARK: - Settings

/// The whole preferences domain as one file, for moving a set-up Aura to another Mac.
struct SettingsBackupCard: View {
    @Environment(DialogManager.self) private var dialogManager
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsCard(
            header: "Settings file",
            description: "Everything on these pages, as JSON. Passwords, history and "
                + "tabs are not in it."
        ) {
            HStack(spacing: 8) {
                OraButton(
                    label: "Export Settings…",
                    variant: .secondary,
                    size: .sm,
                    leadingIcon: "square.and.arrow.up",
                    action: exportSettings
                )
                OraButton(
                    label: "Import Settings…",
                    variant: .secondary,
                    size: .sm,
                    leadingIcon: "square.and.arrow.down",
                    action: confirmImport
                )
                Spacer()
            }

            Text("Imported settings apply after the next launch.")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
        }
    }

    private func exportSettings() {
        Task {
            do {
                let data = try SettingsBackup.export()
                let written = try await DataPortabilityPanels.write(
                    data,
                    suggestedName: "aura-settings.json",
                    contentType: .json
                )
                if written {
                    ToastManager.shared.show("Settings exported.")
                }
            } catch {
                ToastManager.shared.show("Export failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    private func confirmImport() {
        dialogManager.confirm(
            title: "Import settings?",
            message: "Settings the file names are overwritten. Everything it does not "
                + "name stays as it is.",
            confirmLabel: "Choose File…",
            onConfirm: { importSettings() }
        )
    }

    private func importSettings() {
        Task { await runSettingsImport() }
    }

    private func runSettingsImport() async {
        do {
            guard let data = try await DataPortabilityPanels.readSettingsFile() else { return }
            let applied = try SettingsBackup.apply(data)
            guard applied > 0 else {
                ToastManager.shared.show("That file held no Aura settings.", type: .info)
                return
            }
            // Deliberately no reload notification. `SettingsStore` reads every key once,
            // in `init`, and the per-space blobs are cached behind it, so nothing the
            // running app holds changes when `UserDefaults` does. Posting
            // `.javaScriptPolicyChanged` would reload the page in every window and apply
            // none of the imported values, which costs the user their scroll position and
            // form state to achieve nothing. The next launch is what applies them, and
            // the card and this toast both say so.
            ToastManager.shared.show("Imported \(applied) setting\(applied == 1 ? "" : "s"). Restart Aura to apply.")
        } catch {
            ToastManager.shared.show("Import failed: \(error.localizedDescription)", type: .error)
        }
    }
}
