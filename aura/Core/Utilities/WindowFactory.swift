import AppKit
import SwiftUI

enum WindowFactory {
    static func makeMainWindow(rootView: some View, size: CGSize = CGSize(width: 1440, height: 900)) -> NSWindow {
        let window = AuraWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            // `.fullSizeContentView` matches the SwiftUI-made windows. Without it a
            // transparent window stops drawing the frame's rounded corners and shadow.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        // Matches the SwiftUI scenes' `.frame(minWidth:minHeight:)` plus
        // `.windowResizability(.contentMinSize)`; without it this window resizes
        // smaller than any window the scene made.
        window.contentMinSize = NSSize(width: 500, height: 360)
        AuraGlass.applyWindowTransparency(
            to: window,
            enabled: UserDefaults.standard.bool(forKey: AuraGlass.enabledKey)
        )
        window.disableImplicitDragging()
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("normal")

        let hostingController = NSHostingController(rootView: rootView)
        window.contentViewController = hostingController
        // Restores the last position and size. AppKit writes the frame to defaults on
        // every change, so it survives closing the window, not just quitting.
        // From Nook (GPL-3.0), `App/NookApp.swift`, by the Nook authors.
        //
        // A second window cannot claim the same name and keeps the frame set above, so
        // it still centres, which is what every window did before.
        let unplaced = window.frame
        window.setFrameAutosaveName("AuraBrowserWindow")
        if window.frame == unplaced { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    /// Opens a fresh browser window already pointed at `url`.
    ///
    /// The URL is handed to the root directly rather than posted at it: a notification
    /// only lands once the new window's observers are up, which cost a fixed delay
    /// before the page started loading.
    @discardableResult
    static func openWindow(with url: URL) -> NSWindow {
        makeMainWindow(rootView: OraRoot(initialURL: url))
    }
}
