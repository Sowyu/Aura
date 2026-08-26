import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

/// The commands half of `ExtensionManager`: an extension's declared commands (and the
/// `_execute_action` WebKit synthesises for its toolbar button) as bindable shortcuts,
/// and the key monitor that fires them.
///
/// Split out of `ExtensionManager` for size only; everything here is that class.
extension ExtensionManager {
    /// Every loaded extension's commands, as rows the Shortcuts settings can render.
    /// `_execute_action` is in here too: WebKit reports the toolbar button as a command
    /// like any other, so binding a key to it needs no special case.
    func commandShortcuts() -> [ExtensionCommandShortcut] {
        guard #available(macOS 15.4, *), let engine = loadedEngine else { return [] }
        return engine.loadedContexts
            // The explicit result type keeps overload resolution on the
            // sequence-flattening flatMap: a multi-statement closure is not
            // inferred on every compiler this project meets, and the failure
            // mode is picking the deprecated single-value overload.
            .flatMap { id, context -> [ExtensionCommandShortcut] in
                let name = installedExtensions.first { $0.id == id }?.displayName ?? id
                return context.commands.map { command in
                    ExtensionCommandShortcut(
                        id: ExtensionCommandShortcut.id(extensionID: id, commandID: command.id),
                        extensionID: id,
                        commandID: command.id,
                        title: "\(name): \(command.title)",
                        suggested: ExtensionCommands.chord(
                            activationKey: command.activationKey,
                            modifierFlags: command.modifierFlags
                        )
                    )
                }
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Pushes the current bindings onto WebKit's own command objects. That is what makes
    /// `performCommand(for:)` recognise the event, and what the extension reads when it
    /// shows its shortcut in its own interface.
    ///
    /// A suggestion that collides with one of Aura's shortcuts is dropped rather than
    /// honoured: installing an add-on must not take ⌘T away. A chord the user typed in
    /// Settings is kept, collision or not, because that one was a decision.
    func applyCommandShortcuts() {
        guard #available(macOS 15.4, *), let engine = loadedEngine else { return }
        var anyBound = false
        for (id, context) in engine.loadedContexts {
            for command in context.commands {
                let shortcutID = ExtensionCommandShortcut.id(extensionID: id, commandID: command.id)
                let custom = CustomKeyboardShortcutManager.shared.getShortcut(id: shortcutID)
                var chord = custom
                if chord == nil {
                    let suggested = ExtensionCommands.chord(
                        activationKey: command.activationKey,
                        modifierFlags: command.modifierFlags
                    )
                    chord = suggested.flatMap { ExtensionCommands.collidesWithBuiltIn($0) ? nil : $0 }
                }
                let activation = ExtensionCommands.activation(for: chord)
                command.activationKey = activation.key
                command.modifierFlags = activation.flags
                anyBound = anyBound || activation.key != nil
            }
        }
        // No bound command means no reason to watch every key press in the app.
        if anyBound {
            startCommandMonitor()
        } else {
            stopCommandMonitor()
        }
    }

    /// One local key-down monitor, the way the rest of Aura watches keys. WebKit does
    /// the matching against the chords pushed above, so nothing here parses a shortcut.
    @available(macOS 15.4, *)
    private func startCommandMonitor() {
        guard commandMonitor == nil else { return }
        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                (self?.performCommand(for: event) ?? false) ? nil : event
            }
        }
    }

    private func stopCommandMonitor() {
        guard let commandMonitor else { return }
        NSEvent.removeMonitor(commandMonitor)
        self.commandMonitor = nil
    }

    /// True when some extension owned this key press. Aura's own shortcuts are checked
    /// first: a monitor sees the event before the menu bar does, so without this an
    /// extension command bound to ⌘W would eat "close tab".
    @available(macOS 15.4, *)
    private func performCommand(for event: NSEvent) -> Bool {
        guard let engine = loadedEngine, !engine.loadedContexts.isEmpty else { return false }
        guard let chord = KeyChord(fromEvent: event),
              !ExtensionCommands.collidesWithBuiltIn(chord)
        else { return false }
        for context in engine.loadedContexts.values where context.performCommand(for: event) {
            return true
        }
        return false
    }
}
