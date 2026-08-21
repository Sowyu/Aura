import SwiftUI

/// Publishes the live modifier flags and dispatches app-wide key-down events.
///
/// `modifierFlags` updates whenever a modifier is pressed or released. Handlers
/// registered with `registerKeyDownHandler` are tried in order and the first one to
/// return true consumes the event.
///
/// SwiftUI's `.onKeyPress` is not enough here twice over: it only fires for the focused
/// view, and it cannot see a modifier being released at all. Two `NSEvent` local
/// monitors see every event in the app regardless of focus.
///
///     listener.registerKeyDownHandler { event in
///         guard event.modifierFlags.contains(.command), event.keyCode == 12 else {
///             return false
///         }
///         return true // consume it
///     }

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
        for handler in keyDownHandlers where handler(event) {
            return true
        }
        return false
    }
}
