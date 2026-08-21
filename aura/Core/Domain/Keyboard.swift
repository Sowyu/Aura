import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Model types

/// A semantic key combo (persistable key identity + modifiers) with computed vars
/// for a SwiftUI KeyboardShortcut and a display string.
struct KeyChord: Equatable, Codable {
    let keyEquivalent: KeyEquivalent
    let modifiers: SwiftUI.EventModifiers

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: modifiers)
    }

    // MARK: - String-based storage for Codable support

    /// The underlying character as String for Codable support
    private let characterString: String

    /// Initialize from character string (used internally for Codable)
    private init(characterString: String, modifiers: SwiftUI.EventModifiers) {
        self.characterString = characterString
        self.keyEquivalent = KeyEquivalent(Character(characterString))
        self.modifiers = modifiers
    }

    var display: String {
        var parts: [String] = []
        // Display order: control, option, shift, command (follows macOS convention)
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyEquivalent.display)
        return parts.joined()
    }

    init(keyEquivalent: KeyEquivalent, modifiers: SwiftUI.EventModifiers) {
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.characterString = String(keyEquivalent.character)
    }

    /// AppKit's flags to SwiftUI's, in the order the chord is spelled.
    private static let modifierPairs: [(NSEvent.ModifierFlags, SwiftUI.EventModifiers)] = [
        (.command, .command), (.option, .option), (.shift, .shift), (.control, .control)
    ]

    /// Keys with a `KeyEquivalent` of their own. Everything else comes through as a
    /// character.
    private static let namedKeys: [UInt16: KeyEquivalent] = [
        UInt16(kVK_Tab): .tab,
        UInt16(kVK_LeftArrow): .leftArrow,
        UInt16(kVK_RightArrow): .rightArrow,
        UInt16(kVK_DownArrow): .downArrow,
        UInt16(kVK_UpArrow): .upArrow,
        UInt16(kVK_Escape): .escape,
        UInt16(kVK_Return): .return,
        UInt16(kVK_Space): .space,
        UInt16(kVK_Delete): .delete,
        UInt16(kVK_ForwardDelete): .deleteForward
    ]

    init?(fromEvent event: NSEvent) {
        let flags = event.modifierFlags
        var mods: SwiftUI.EventModifiers = []
        for (flag, modifier) in Self.modifierPairs where flags.contains(flag) {
            mods.insert(modifier)
        }

        let typed = event.charactersIgnoringModifiers?.first.map { KeyEquivalent($0) }
        guard let keyEquivalent = Self.namedKeys[event.keyCode] ?? typed else { return nil }

        self.keyEquivalent = keyEquivalent
        self.modifiers = mods
        self.characterString = String(keyEquivalent.character)
    }

    // Codable Support

    private enum CodingKeys: String, CodingKey {
        case characterString, modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.characterString = try container.decode(String.self, forKey: .characterString)
        let rawModifiers = try container.decode(Int.self, forKey: .modifiers)
        self.modifiers = SwiftUI.EventModifiers(rawValue: rawModifiers)
        self.keyEquivalent = KeyEquivalent(Character(characterString))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(characterString, forKey: .characterString)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
    }
}

/// A keyboard shortcut definition with all necessary information
struct KeyboardShortcutDefinition: Identifiable, Equatable {
    let id: String
    let name: String
    let category: String
    let defaultChord: KeyChord

    /// Current chord (either custom override or default)
    var currentChord: KeyChord {
        if let custom = CustomKeyboardShortcutManager.shared.getShortcut(id: id) {
            return custom
        }
        return defaultChord
    }

    /// SwiftUI KeyboardShortcut for use in views
    var keyboardShortcut: KeyboardShortcut {
        currentChord.keyboardShortcut
    }

    /// Display string for the current shortcut (used in settings UI)
    var display: String {
        currentChord.display
    }
}

// MARK: - KeyEquivalent Display Extension

extension KeyEquivalent {
    var display: String {
        switch self {
        case .tab: return "⇥"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .downArrow: return "↓"
        case .upArrow: return "↑"
        case .escape: return "⎋"
        case .return: return "↩"
        case .space: return "␣"
        case .delete: return "⌫"
        case .deleteForward: return "⌦"
        default:
            // For character keys, return uppercased
            return String(character).uppercased()
        }
    }
}
