import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The single overlay every Aura menu draws into. Installed once per window, in
/// `BrowserView`'s outer `ZStack`.
///
/// While no menu is open it renders an empty stack and installs no event monitors, so a
/// closed menu costs nothing. Pointer tracking runs off `NSEvent` monitors rather than
/// SwiftUI gestures: the panels sit above a `WKWebView`, and an AppKit event monitor is
/// the only thing guaranteed to see the click before the web view does.
struct AuraMenuHost: View {
    @ObservedObject private var controller = AuraMenuController.shared
    @Environment(\.window) private var window

    @State private var monitors: [Any] = []
    @State private var resignObserver: NSObjectProtocol?
    @State private var hoverWork: DispatchWorkItem?
    /// The overlay's own top-left in window coordinates; panels are positioned relative
    /// to the window, and the host does not always start at the window's corner.
    @State private var hostOrigin: CGPoint = .zero

    private var isMine: Bool {
        controller.isOpen && controller.window === window
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isMine {
                ForEach(Array(controller.levels.enumerated()), id: \.element.id) { index, level in
                    AuraMenuPanel(level: level, levelIndex: index)
                        .offset(x: level.origin.x - hostOrigin.x, y: level.origin.y - hostOrigin.y)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .background(WindowOriginReader { hostOrigin = $0 })
        .animation(AnimationSettings.easeOut(0.1), value: controller.levels.map(\.id))
        .onChange(of: isMine, initial: true) { _, open in
            if open { startTracking() } else { stopTracking() }
        }
        .onDisappear(perform: stopTracking)
    }

    // MARK: - Event tracking

    private func startTracking() {
        stopTracking()
        let mouseMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .mouseMoved, .leftMouseDragged, .scrollWheel
        ]
        // Only plain values cross into the handler: NSEvent is not Sendable, and capturing
        // it inside the isolated closure is an error under the Swift 6 language mode.
        let mouse = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { event in
            let type = event.type
            let location = event.locationInWindow
            let eventWindow = event.window
            let handled = MainActor.assumeIsolated {
                handleMouse(type: type, location: location, in: eventWindow)
            }
            return handled ? nil : event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            let modifiers = event.modifierFlags
            let character = event.charactersIgnoringModifiers?.first
            let handled = MainActor.assumeIsolated {
                handleKey(code: code, modifiers: modifiers, character: character)
            }
            return handled ? nil : event
        }
        monitors = [mouse, keys].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AuraMenuController.shared.dismiss() }
        }
    }

    private func stopTracking() {
        hoverWork?.cancel()
        hoverWork = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    // MARK: - Mouse

    /// Returns true when the menu consumed the event.
    @MainActor
    private func handleMouse(type: NSEvent.EventType, location: CGPoint, in eventWindow: NSWindow?) -> Bool {
        guard controller.isOpen,
              let menuWindow = controller.window,
              eventWindow === menuWindow,
              let content = menuWindow.contentView
        else {
            return false
        }

        let point = CGPoint(x: location.x, y: content.bounds.height - location.y)
        let target = controller.hit(point)

        switch type {
        case .mouseMoved, .leftMouseDragged:
            hover(target)
            return target != nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let target else {
                controller.dismiss()
                return true
            }
            // Only the left button arms a row; a right-click inside the menu is swallowed
            // so it cannot leave a row stuck in the pressed state.
            if type == .leftMouseDown {
                press(target)
            }
            return true
        case .leftMouseUp:
            guard let target, let row = target.row else {
                controller.press(row: nil, atLevel: controller.deepest)
                return target != nil
            }
            if controller.levels[target.level].pressed == row {
                controller.press(row: nil, atLevel: target.level)
                controller.activate(level: target.level, row: row)
            }
            return true
        case .scrollWheel:
            controller.dismiss()
            return true
        default:
            return false
        }
    }

    @MainActor
    private func hover(_ target: (level: Int, row: Int?)?) {
        hoverWork?.cancel()
        guard let target else {
            controller.highlight(row: nil, atLevel: controller.deepest)
            return
        }

        for level in controller.levels.indices {
            if level == target.level {
                controller.highlight(row: target.row, atLevel: level)
            } else if level < target.level {
                controller.highlight(row: controller.levels[level + 1].parentRow, atLevel: level)
            } else {
                controller.highlight(row: nil, atLevel: level)
            }
        }

        // 120 ms of grace, so a diagonal run into an open submenu does not close it on the
        // way past its neighbours. ponytail: no pointer-triangle heuristic; add one if
        // wide submenus start closing under a slow diagonal.
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let controller = AuraMenuController.shared
                if let row = target.row, controller.item(atLevel: target.level, row: row)?.kind == .submenu {
                    controller.openSubmenu(atLevel: target.level, row: row)
                } else {
                    controller.closeLevels(deeperThan: target.level)
                }
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @MainActor
    private func press(_ target: (level: Int, row: Int?)) {
        hoverWork?.cancel()
        // Clicking the row that already owns the open submenu must not tear it down and
        // rebuild it, which would flash the panel.
        let ownsOpenSubmenu = controller.levels.count > target.level + 1
            && controller.levels[target.level + 1].parentRow == target.row
        if !ownsOpenSubmenu {
            controller.closeLevels(deeperThan: target.level)
        }
        controller.press(row: target.row, atLevel: target.level)
        guard let row = target.row else { return }
        // A click on a submenu row opens it now rather than after the hover delay.
        if controller.item(atLevel: target.level, row: row)?.kind == .submenu {
            controller.openSubmenu(atLevel: target.level, row: row)
        }
    }

    // MARK: - Keyboard

    /// Returns true when the menu consumed the key.
    @MainActor
    // swiftlint:disable:next cyclomatic_complexity
    private func handleKey(code: Int, modifiers: NSEvent.ModifierFlags, character: Character?) -> Bool {
        guard controller.isOpen else { return false }
        hoverWork?.cancel()
        let level = controller.deepest

        switch code {
        case kVK_DownArrow:
            controller.moveHighlight(by: 1)
        case kVK_UpArrow:
            controller.moveHighlight(by: -1)
        case kVK_RightArrow:
            if let row = controller.levels[level].highlighted,
               controller.item(atLevel: level, row: row)?.kind == .submenu
            {
                controller.activate(level: level, row: row)
            }
        case kVK_LeftArrow:
            controller.closeLevels(deeperThan: level - 1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            if let row = controller.levels[level].highlighted {
                controller.activate(level: level, row: row)
            }
        case kVK_Escape:
            if level > 0 {
                controller.closeLevels(deeperThan: level - 1)
            } else {
                controller.dismiss()
            }
        default:
            // A real shortcut belongs to the app, so the menu gets out of the way first.
            guard modifiers.isDisjoint(with: [.command, .control]) else {
                controller.dismiss()
                return false
            }
            if let character, character.isLetter || character.isNumber {
                controller.selectFirst(matching: character)
            }
        }
        return true
    }
}

/// Reports the overlay's top-left corner in window coordinates so panels placed against
/// the window can be drawn at the right spot inside it.
private struct WindowOriginReader: NSViewRepresentable {
    let onChange: (CGPoint) -> Void

    final class OriginView: NSView {
        /// Spans the whole window above the chrome; AppKit hit-tests this real view before
        /// SwiftUI ever sees the click, so it must decline or every button goes dead.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        var onChange: ((CGPoint) -> Void)?
        private var reported: CGPoint?

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        /// Deferred and de-duplicated: `layout()` can run inside a SwiftUI update, and
        /// writing `@State` from there would warn or loop.
        private func report() {
            guard let window, let content = window.contentView else { return }
            let rect = convert(bounds, to: nil)
            let origin = CGPoint(x: rect.minX, y: content.bounds.height - rect.maxY)
            guard origin != reported else { return }
            reported = origin
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(origin)
            }
        }
    }

    func makeNSView(context: Context) -> OriginView {
        let view = OriginView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: OriginView, context: Context) {
        nsView.onChange = onChange
    }
}
