import AppKit
import SwiftUI
import Testing
@testable import Aura

@MainActor
struct PolishRegressionTests {
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
