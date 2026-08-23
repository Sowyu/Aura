import AppKit
import SwiftUI

/// One extension command, in the shape the rest of Aura's shortcut machinery uses.
///
/// A manifest's `commands` (and the `_execute_action` WebKit synthesises for the
/// toolbar button) become ordinary bindable shortcuts: same settings list, same
/// storage, same "reset to default" as ⌘T. The id is namespaced by extension so two
/// add-ons declaring `toggle` do not share a binding, and so an uninstall can drop
/// every binding an extension owned by prefix.
struct ExtensionCommandShortcut: Identifiable, Equatable {
    let id: String
    let extensionID: String
    let commandID: String
    /// The extension's own word for the command, which is what the user recognises.
    let title: String
    /// The chord the extension suggested in its manifest, when it suggested one.
    let suggested: KeyChord?

    static let category = "Extensions"
    static let idPrefix = "extensions."

    static func id(extensionID: String, commandID: String) -> String {
        "\(idPrefix)\(extensionID).\(commandID)"
    }

    /// Every binding id that belongs to one extension starts with this.
    static func idPrefix(forExtension extensionID: String) -> String {
        "\(idPrefix)\(extensionID)."
    }

    /// The row the Shortcuts settings renders. A command with no suggestion still needs
    /// a chord here (the type has no room for "none"), so it gets one that cannot be
    /// typed; `display` is what the row actually shows.
    var definition: KeyboardShortcutDefinition {
        KeyboardShortcutDefinition(
            id: id,
            name: title,
            category: Self.category,
            defaultChord: suggested ?? ExtensionCommands.unboundChord
        )
    }

    /// The current binding, which is the user's if they set one and the extension's
    /// suggestion otherwise. Nil when the command has no shortcut at all.
    var chord: KeyChord? {
        CustomKeyboardShortcutManager.shared.getShortcut(id: id) ?? suggested
    }

    var display: String {
        chord?.display ?? "Not set"
    }
}

/// The pure half of the commands bridge: ids, chord conversion, and which chords an
/// extension is not allowed to take.
enum ExtensionCommands {
    /// Stands in for "no shortcut". A null character cannot be typed, so this never
    /// matches an event even if something asked WebKit to use it.
    static let unboundChord = KeyChord(keyEquivalent: KeyEquivalent("\0"), modifiers: [])

    private static let modifierPairs: [(NSEvent.ModifierFlags, SwiftUI.EventModifiers)] = [
        (.command, .command), (.option, .option), (.shift, .shift), (.control, .control)
    ]

    /// WebKit's spelling of a command's shortcut turned into Aura's.
    static func chord(activationKey: String?, modifierFlags: NSEvent.ModifierFlags) -> KeyChord? {
        guard let character = activationKey?.first else { return nil }
        var modifiers: SwiftUI.EventModifiers = []
        for (flag, modifier) in modifierPairs where modifierFlags.contains(flag) {
            modifiers.insert(modifier)
        }
        return KeyChord(keyEquivalent: KeyEquivalent(character), modifiers: modifiers)
    }

    /// Aura's spelling turned back into WebKit's, which is what makes the extension
    /// display the right shortcut in its own interface and lets WebKit match the event.
    static func activation(for chord: KeyChord?) -> (key: String?, flags: NSEvent.ModifierFlags) {
        guard let chord, chord != unboundChord else { return (nil, []) }
        var flags: NSEvent.ModifierFlags = []
        for (flag, modifier) in modifierPairs where chord.modifiers.contains(modifier) {
            flags.insert(flag)
        }
        return (String(chord.keyEquivalent.character), flags)
    }

    /// True when a chord is already one of Aura's own shortcuts.
    ///
    /// An extension suggests its shortcut in its manifest, and nothing stops it from
    /// suggesting ⌘T. The browser's own keys win; the user can still hand the chord
    /// over deliberately in Settings, because a binding they typed is not a suggestion.
    static func collidesWithBuiltIn(_ chord: KeyChord) -> Bool {
        KeyboardShortcuts.allShortcuts.contains { $0.currentChord == chord }
    }
}
