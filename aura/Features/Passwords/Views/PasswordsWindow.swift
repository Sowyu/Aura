import AppKit
import SwiftData
import SwiftUI

@MainActor
func openPasswordsWindow() {
    PasswordsWindowController.shared.show()
}

@MainActor
private final class PasswordsWindowController: NSObject, NSWindowDelegate {
    static let shared = PasswordsWindowController()

    private let sharedModelContainer = try? ModelConfiguration.createOraContainer(isPrivate: false)
    private var windowController: NSWindowController?

    func show() {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let rootView = if let sharedModelContainer {
            AnyView(
                PasswordsWindowView()
                    .modelContainer(sharedModelContainer)
                    .withTheme()
            )
        } else {
            AnyView(
                PasswordsWindowUnavailableView()
                    .withTheme()
            )
        }

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Passwords"
        window.minSize = CGSize(width: 960, height: 480)
        window.center()
        window.delegate = self
        window.contentViewController = hostingController
        window.setFrameAutosaveName("PasswordsWindow")

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === windowController?.window
        else {
            return
        }

        windowController = nil
    }
}

private struct PasswordsWindowUnavailableView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            Text("Passwords are unavailable because the shared data store could not be opened.")
                .font(.system(size: 13))
                .foregroundStyle(theme.mutedForeground)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(minWidth: 960, minHeight: 480)
    }
}

private struct PasswordsWindowView: View {
    @Query(sort: \TabContainer.lastAccessedAt, order: .reverse) var containers: [TabContainer]

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            // The whole vault is `PasswordVaultView`, shared with the Passwords settings
            // section. The window gives the table every point it has left; the settings
            // card, being inside a scroll view, pins it to a fixed height instead.
            PasswordVaultView(title: "Saved passwords", containers: containers)
                .padding(20)
        }
        .frame(minWidth: 960, minHeight: 480)
    }
}
