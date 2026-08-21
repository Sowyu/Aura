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
}
