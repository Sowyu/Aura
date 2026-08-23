import AppKit
@testable import Aura
import Foundation
import SwiftUI
import Testing
import WebKit

/// An extension's `commands` (and the `_execute_action` WebKit synthesises for the
/// toolbar button) become ordinary bindable shortcuts. The conversion between Aura's
/// `KeyChord` and WebKit's activation key has to survive both directions, and an
/// add-on's suggestion must not be able to take one of the browser's own keys.
struct ExtensionCommandsTests {
    @Test func chordsConvertBothWays() {
        let chord = ExtensionCommands.chord(activationKey: "y", modifierFlags: [.control, .shift])
        #expect(chord == KeyChord(keyEquivalent: KeyEquivalent("y"), modifiers: [.control, .shift]))

        let activation = ExtensionCommands.activation(for: chord)
        #expect(activation.key == "y")
        #expect(activation.flags == [.control, .shift])
        #expect(!activation.flags.contains(.command))
    }

    /// A command with no suggested key is the common case, and it has to read as "no
    /// shortcut" rather than as some key the user cannot type.
    @Test func anUnboundCommandHasNoActivationKey() {
        #expect(ExtensionCommands.chord(activationKey: nil, modifierFlags: []) == nil)
        #expect(ExtensionCommands.chord(activationKey: "", modifierFlags: [.command]) == nil)

        let unbound = ExtensionCommands.activation(for: ExtensionCommands.unboundChord)
        #expect(unbound.key == nil)
        #expect(unbound.flags.isEmpty)
        #expect(ExtensionCommands.activation(for: nil).key == nil)
    }

    /// Installing an add-on must not take ⌘T away from the browser.
    @Test func aSuggestionCannotStealABuiltInShortcut() {
        let newTab = KeyboardShortcuts.Tabs.new.currentChord
        #expect(ExtensionCommands.collidesWithBuiltIn(newTab))
        let free = KeyChord(keyEquivalent: KeyEquivalent("y"), modifiers: [.control, .shift, .option])
        #expect(!ExtensionCommands.collidesWithBuiltIn(free))
    }

    /// Bindings are namespaced by extension so two add-ons declaring `toggle` do not
    /// share one, and so an uninstall can drop them all by prefix.
    @Test func bindingIDsAreNamespacedByExtension() {
        let id = ExtensionCommandShortcut.id(extensionID: "ublock-origin", commandID: "toggle")
        #expect(id == "extensions.ublock-origin.toggle")
        #expect(id.hasPrefix(ExtensionCommandShortcut.idPrefix(forExtension: "ublock-origin")))
        #expect(!id.hasPrefix(ExtensionCommandShortcut.idPrefix(forExtension: "other")))
    }

    @Test func anUnboundRowSaysSoInsteadOfShowingAKey() {
        let shortcut = ExtensionCommandShortcut(
            id: "extensions.test.toggle",
            extensionID: "test",
            commandID: "toggle",
            title: "Test: Toggle",
            suggested: nil
        )
        #expect(shortcut.display == "Not set")
        #expect(shortcut.chord == nil)
        #expect(shortcut.definition.category == ExtensionCommandShortcut.category)

        let bound = ExtensionCommandShortcut(
            id: "extensions.test.other",
            extensionID: "test",
            commandID: "other",
            title: "Test: Other",
            suggested: KeyChord(keyEquivalent: KeyEquivalent("y"), modifiers: [.command, .shift])
        )
        #expect(bound.display == "⇧⌘Y")
    }

    // MARK: - Against WebKit

    /// WebKit is what matches the key press, so the chords Aura hands it have to be
    /// ones it accepts and reports back unchanged.
    @Test @MainActor func webKitTakesTheChordsAuraPushesOntoACommand() async throws {
        guard #available(macOS 15.4, *) else {
            Issue.record("Requires macOS 15.4; host OS too old to run this check")
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Command Test",
            "version": "1.0",
            "action": ["default_title": "Command Test"],
            "commands": [
                "toggle-thing": [
                    "suggested_key": ["default": "Ctrl+Shift+Y"],
                    "description": "Toggle the thing"
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("manifest.json"))

        let engine = ExtensionEngine()
        _ = try await engine.load(directory: directory, id: "command-test")
        defer { engine.unload(id: "command-test") }
        let context = try #require(engine.context(for: "command-test"))

        let command = try #require(context.commands.first { $0.id == "toggle-thing" })
        #expect(!command.title.isEmpty)
        // What the manifest suggested, read back as a chord Aura can show and store.
        let suggested = ExtensionCommands.chord(
            activationKey: command.activationKey, modifierFlags: command.modifierFlags
        )
        #expect(suggested?.keyEquivalent.character == "y")

        // The rebind path: what Settings writes has to land on WebKit's own object.
        let rebound = KeyChord(keyEquivalent: KeyEquivalent("j"), modifiers: [.command, .option])
        let activation = ExtensionCommands.activation(for: rebound)
        command.activationKey = activation.key
        command.modifierFlags = activation.flags
        #expect(command.activationKey == "j")
        #expect(command.modifierFlags.contains(.command))
        #expect(command.modifierFlags.contains(.option))
        #expect(
            ExtensionCommands.chord(activationKey: command.activationKey, modifierFlags: command.modifierFlags)
                == rebound,
            "a chord has to survive the trip through WebKit unchanged"
        )
    }
}
