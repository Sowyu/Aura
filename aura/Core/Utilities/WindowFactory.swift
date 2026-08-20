import AppKit
import SwiftUI

enum WindowFactory {
    static func makeMainWindow(rootView: some View, size: CGSize = CGSize(width: 1440, height: 900)) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.disableImplicitDragging()
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("normal")

        let hostingController = NSHostingController(rootView: rootView)
        window.contentViewController = hostingController
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    /// Opens a fresh browser window already pointed at `url`.
    ///
    /// ponytail: the URL is delivered by notification after a beat, because the new
    /// window's root installs its observers on the next run loop turn. Swap this for a
    /// real initial-URL parameter on `OraRoot` if the delay ever shows.
    static func openWindow(with url: URL) {
        let window = makeMainWindow(rootView: OraRoot())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .openURL, object: window, userInfo: ["url": url])
        }
    }
}
