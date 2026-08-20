import SwiftUI

/*
 * KeyModifierListener is an ObservableObject that monitors keyboard modifier key changes and global key down events.
 *
 * It publishes the current modifier flags via the `modifierFlags` property, which updates whenever modifier keys are pressed or released.
 *
 * Additionally, it allows registering custom handlers for key down events using `registerKeyDownHandler`.
 * If any registered handler returns true, the event is consumed and not propagated further.
 *
 *
 * Why not use onKeyPressed?
 *
 * SwiftUI's .onKeyPress modifier is attached to specific views and only triggers when that view has keyboard focus.
 * In contrast, KeyModifierListener uses NSEvent monitors to capture modifier flag changes and key down events
 * globally across the entire application,
 * regardless of focus. This enables app-wide keyboard shortcuts and consistent modifier state tracking.
 *
 * Also, it's not possible to use onKeyPressed to detect modifier key changes like if modifier is released.
 *
 * Usage:
 * let listener = KeyModifierListener()
 * @StateObject var keyListener = listener // In a SwiftUI View
 *
 * listener.registerKeyDownHandler { event in
 *     if event.modifierFlags.contains(.command) && event.keyCode == 12 { // Command + Q
 *         print("Command + Q pressed")
 *         return true // Consume the event
 *     }
 *     return false
 * }
 */

final class KeyModifierListener: ObservableObject {
    @Published var modifierFlags = NSEvent.ModifierFlags([])

    /// The window this listener belongs to. When set, key-down events from
    /// other windows are ignored (local monitors see every window's events).
    /// Once a window has been assigned, its deallocation must fail closed —
    /// otherwise a listener leaked from a closed window consumes every
    /// surviving window's key events.
    weak var window: NSWindow? {
        didSet { windowWasSet = true }
    }

    private var windowWasSet = false
    private var monitors: [Any] = []

    init() {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.modifierFlags = event.modifierFlags
            return event
        }) {
            monitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            if self.windowWasSet, event.window !== self.window {
                return event
            }
            if self.handleGlobalKeyDown(event) {
                return nil
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    typealias KeyDownHandler = (NSEvent) -> Bool

    private var keyDownHandlers: [KeyDownHandler] = []

    func registerKeyDownHandler(_ handler: @escaping KeyDownHandler) {
        keyDownHandlers.append(handler)
    }

    func removeAllKeyDownHandlers() {
        keyDownHandlers.removeAll()
    }

    private func handleGlobalKeyDown(_ event: NSEvent) -> Bool {
        for handler in keyDownHandlers {
            if handler(event) {
                return true
            }
        }
        return false
    }
}
