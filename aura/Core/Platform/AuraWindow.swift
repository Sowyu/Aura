import AppKit

/// Ported from Refrax (GPL-3.0), `Refrax/Core/ViewControllers/RefraxWindow.swift`
/// by the Refrax authors. Only the first-responder lock is taken; Refrax's styling and
/// state restoration are set up elsewhere in Aura. See THIRD_PARTY_NOTICES.md.
///
/// A window that can pin first responder to one view.
///
/// Switching apps away and back hands first responder to whatever AppKit likes, which
/// drops the address field mid-edit and swallows the next keystroke. While
/// `lockedFirstResponder` is set, nothing but that view and its field editor can take it.
final class AuraWindow: NSWindow {
    weak var lockedFirstResponder: NSView?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        // Only refuse while the app is away. Refrax locks unconditionally; here a click
        // on the page has to be able to take focus off the address field like always.
        guard let locked = lockedFirstResponder, !NSApp.isActive else {
            return super.makeFirstResponder(responder)
        }
        if responder === locked {
            return super.makeFirstResponder(responder)
        }
        // An NSTextField edits through a shared NSTextView that becomes the real first
        // responder. Blocking that would stop typing altogether.
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            return super.makeFirstResponder(responder)
        }
        return false
    }

    override func becomeKey() {
        super.becomeKey()
        // The override above refuses a steal, but deactivation may already have moved
        // first responder before this window was key again, so put it back.
        if let locked = lockedFirstResponder {
            _ = makeFirstResponder(locked)
        }
    }
}

/// Keeps the field focused across an app switch in both kinds of window Aura opens.
///
/// `WindowFactory` makes `AuraWindow`s, which can refuse the steal outright. The windows
/// SwiftUI makes for its own scenes are plain `NSWindow`s and cannot, so there the focus
/// is taken back once the window is key again.
@MainActor
final class FirstResponderLock {
    private weak var view: NSView?
    private var observer: NSObjectProtocol?

    init(view: NSView) {
        self.view = view
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var isLocked: Bool { observer != nil }

    func lock() {
        guard let view, let window = view.window, observer == nil else { return }
        (window as? AuraWindow)?.lockedFirstResponder = view
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let view = self?.view, let window = view.window, window.isKeyWindow,
                      window.firstResponder !== view,
                      (view as? NSTextField)?.currentEditor() !== window.firstResponder
                else { return }
                _ = window.makeFirstResponder(view)
            }
        }
    }

    func unlock() {
        if let view, let window = view.window, (window as? AuraWindow)?.lockedFirstResponder === view {
            (window as? AuraWindow)?.lockedFirstResponder = nil
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
