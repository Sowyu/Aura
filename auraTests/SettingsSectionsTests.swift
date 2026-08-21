import AppKit
import Foundation
@testable import Aura
import Testing

/// The settings sidebar and the one rule that decides where a download lands.
struct SettingsSectionsTests {
    @Test func everySectionHasATitleAndAnSFSymbol() {
        for tab in SettingsTab.allCases {
            #expect(!tab.title.isEmpty, "\(tab) has no title")
            #expect(!tab.symbol.isEmpty, "\(tab) has no symbol")
            #expect(!tab.subtitle.isEmpty, "\(tab) has no subtitle")
            #expect(
                NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil) != nil,
                "\(tab.symbol) is not an SF Symbol"
            )
        }
    }

    @Test func savedSelectionsFromOlderBuildsStillResolve() {
        #expect(SettingsTab.resolve(rawValue: "general") == .lookAndFeel)
        #expect(SettingsTab.resolve(rawValue: "searchEngines") == .search)
        // Sections that kept their raw value must keep resolving to themselves.
        #expect(SettingsTab.resolve(rawValue: "spaces") == .spaces)
        #expect(SettingsTab.resolve(rawValue: "passwords") == .passwords)
        #expect(SettingsTab.resolve(rawValue: "shortcuts") == .shortcuts)
        #expect(SettingsTab.resolve(rawValue: "extensions") == .extensions)
        #expect(SettingsTab.resolve(rawValue: "notASection") == nil)
    }

    @Test func downloadsGoToTheChosenFolderUnlessAskingIsOn() {
        let systemDownloads = URL(fileURLWithPath: "/Users/test/Downloads")
        let chosen = URL(fileURLWithPath: "/Volumes/Work/Incoming")

        #expect(
            DownloadDestination.resolve(
                askWhereToSave: false,
                chosenFolder: nil,
                systemDownloads: systemDownloads
            ) == .folder(systemDownloads)
        )
        #expect(
            DownloadDestination.resolve(
                askWhereToSave: false,
                chosenFolder: chosen,
                systemDownloads: systemDownloads
            ) == .folder(chosen)
        )
        // Asking wins over a chosen folder: the panel just opens there.
        #expect(
            DownloadDestination.resolve(
                askWhereToSave: true,
                chosenFolder: chosen,
                systemDownloads: systemDownloads
            ) == .ask
        )
    }

    @Test func everySectionHasAWorkingDeepLink() {
        for tab in SettingsTab.allCases {
            let url = URL.oraSettings(section: tab)
            #expect(url.isOraSettings, "\(tab) does not produce a settings URL")
            #expect(url.oraSettingsSection == tab, "\(url) does not resolve back to \(tab)")
        }
        // No section means the page keeps whatever the user last had open.
        #expect(URL.oraSettings().oraSettingsSection == nil)
    }

    @MainActor @Test func scriptableImageFormatsNeverOpenThemselves() {
        // SVG carries <script> and its default handler is usually a browser.
        #expect(!DownloadManager.safeExtensions.contains("svg"))
        #expect(!DownloadManager.safeExtensions.contains("html"))
        #expect(DownloadManager.safeExtensions.contains("png"))
        #expect(DownloadManager.safeExtensions.contains("pdf"))
    }

    /// `expectedContentLength` is -1 when the server sends no Content-Length, and
    /// `WKDownload` reports 0 until the first byte lands. Neither may reach the row.
    @Test func downloadKeepsTheLastKnownSizeWhenTheServerReportsNone() {
        let download = Download(
            originalURL: URL(string: "https://example.com/f.bin")!,
            fileName: "f.bin",
            fileSize: -1
        )
        #expect(download.fileSize == 0)

        download.updateProgress(downloadedBytes: 512, totalBytes: -1)
        #expect(download.fileSize == 0)
        #expect(download.progress == 0)

        download.updateProgress(downloadedBytes: 512, totalBytes: 1024)
        #expect(download.fileSize == 1024)
        #expect(download.progress == 0.5)

        // A later tick with no size must not wipe the size already learned.
        download.updateProgress(downloadedBytes: 768, totalBytes: 0)
        #expect(download.fileSize == 1024)
        #expect(download.progress == 0.75)
    }

    /// The initialiser ignored both date arguments and stamped `Date()` instead, so an
    /// imported visit claimed to have happened just now.
    @Test func historyKeepsTheDatesItWasGiven() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let accessed = Date(timeIntervalSince1970: 2_000_000)
        let entry = History(
            url: URL(string: "https://example.com")!,
            title: "Example",
            faviconURL: URL(string: "https://example.com/favicon.ico")!,
            createdAt: created,
            lastAccessedAt: accessed,
            visitCount: 3
        )
        #expect(entry.createdAt == created)
        #expect(entry.lastAccessedAt == accessed)
    }
}
