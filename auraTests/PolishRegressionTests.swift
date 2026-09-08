import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Aura

@MainActor
struct PolishRegressionTests {
    @Test func disappearingRowsOnlyClearTheirOwnPointerState() {
        let pointer = TabRowPointer()
        let first = UUID(), second = UUID()
        pointer.setPointerOnRow(first, true)
        pointer.setPointerOnRow(second, true)
        pointer.setPointerOnRow(first, false)
        #expect(pointer.pointerOnRow)
        pointer.setPointerOnRow(second, false)
        #expect(!pointer.pointerOnRow)
    }

    @Test func onlyUserActivatedExternalSchemesLeaveTheBrowser() {
        #expect(BrowserPage.opensExternally(URL(string: "mailto:hello@example.com"), navigationType: .linkActivated))
        #expect(!BrowserPage.opensExternally(URL(string: "zoommtg://join"), navigationType: .other))
        for scheme in ["https", "javascript", "data", "blob", "aura", "webkit-extension"] {
            #expect(!BrowserPage.opensExternally(URL(string: "\(scheme):test"), navigationType: .linkActivated))
        }
    }

    @Test func internalPagesHaveNoSitePermissionsOrSecurityWarning() {
        for address in ["aura://home", "file:///tmp/page.html", "about:blank", "data:text/plain,test"] {
            let url = URL(string: address)!
            #expect(!SiteInfoSummary.hasSite(url))
            #expect(SiteInfoSummary.securitySymbol(for: url) == "globe")
        }
        #expect(SiteInfoSummary.securitySymbol(for: URL(string: "http://example.com")!) == "exclamationmark.triangle")
        #expect(SiteInfoSummary.securitySymbol(for: URL(string: "https://example.com")!) == "lock.shield")
    }

    @Test func searchTemplatesRequireAWebHostAndQuery() {
        #expect(CustomSearchEngine.isValidTemplate("https://example.com/?q={query}"))
        for invalid in ["example.com/{query}", "javascript:{query}", "https:///", "https://example.com/"] {
            #expect(!CustomSearchEngine.isValidTemplate(invalid))
        }
    }

    @Test func customDialogReturnKeepsOneConfirmationAction() throws {
        let manager = DialogManager()
        var confirmations = 0
        manager.show(onConfirm: { confirmations += 1 }) { _ in Text("Confirm") }
        let dialog = try #require(manager.dialogs.last)
        dialog.onConfirm?()
        manager.dismiss(id: dialog.id)
        #expect(confirmations == 1)
        #expect(manager.dialogs.isEmpty)
    }

    @Test func emojiCatalogKeepsStableIdentitiesAcrossOpenings() {
        let first = EmojiViewModel()
        let second = EmojiViewModel()
        #expect(first.categories.map(\.id) == second.categories.map(\.id))
        #expect(first.error == second.error)
    }

    @Test func retiredShortcutsNeverAppearInTheRecorder() {
        for id in CustomKeyboardShortcutManager.retiredShortcutIDs {
            #expect(!KeyboardShortcuts.allShortcuts.contains { $0.id == id })
        }
        #expect(KeyboardShortcuts.allShortcuts.contains { $0.id == "window.toggleCompactMode" })
    }
}
