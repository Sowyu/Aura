import SwiftUI

/// Attach app shortcuts that update as overrides change.
private struct AuraKeyboardShortcutModifier: ViewModifier {
    let shortcut: KeyboardShortcutDefinition
    @EnvironmentObject private var shortcutManager: CustomKeyboardShortcutManager

    func body(content: Content) -> some View {
        content
            .keyboardShortcut(shortcut.keyboardShortcut)
    }
}

/// Attach a tooltip that includes the current shortcut display.
private struct AuraShortcutHelpModifier: ViewModifier {
    let helpText: String
    let shortcut: KeyboardShortcutDefinition
    @EnvironmentObject private var shortcutManager: CustomKeyboardShortcutManager

    func body(content: Content) -> some View {
        content
            .help("\(helpText) (\(shortcut.currentChord.display))")
            // Every caller is an icon-only chrome button, which otherwise reaches
            // VoiceOver as the SF Symbol's name or as nothing at all. The label is the
            // plain words: the chord belongs in the tooltip, where it reads as one.
            .accessibilityLabel(Text(helpText))
    }
}

extension View {
    /// Use in place of `.keyboardShortcut` to auto-update on custom shortcut changes.
    func auraShortcut(_ shortcut: KeyboardShortcutDefinition) -> some View {
        modifier(AuraKeyboardShortcutModifier(shortcut: shortcut))
    }

    /// Helper to keep tooltips in sync with the current shortcut mapping.
    /// Results in a tooltip like: "Copy URL (⇧⌘C)"
    func auraShortcutHelp(_ helpText: String, for shortcut: KeyboardShortcutDefinition) -> some View {
        modifier(AuraShortcutHelpModifier(helpText: helpText, shortcut: shortcut))
    }
}
