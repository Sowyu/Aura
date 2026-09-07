import AppKit
import SwiftUI
import Testing

@testable import Aura

/// ⌘T has to land the caret in the field. The launcher relied on SwiftUI's focus bridge
/// onto its `NSViewRepresentable`, which did not reliably make the field first responder;
/// the address bar and the home page ask AppKit directly. This mounts the launcher's own
/// panel in a real window and checks the field editor is first responder.
@MainActor
struct LauncherFocusTests {
    private struct Probe: View {
        @State private var text = ""
        @State private var match: LauncherMatch?
        @FocusState private var focused: Bool
        @StateObject private var viewModel = LauncherViewModel()

        var body: some View {
            LauncherMain(
                text: $text,
                match: $match,
                isFocused: $focused,
                onTabPress: {},
                onEscape: {},
                viewModel: viewModel
            )
            .onAppear { focused = true }
        }
    }

    /// The field editor the launcher's text field edits through, if it is first responder.
    private static func launcherFieldEditor(in window: NSWindow) -> NSTextView? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              editor.delegate is LauncherTextField.CustomTextField
        else { return nil }
        return editor
    }

    @Test func thePanelTakesTheCaretWhenItAppears() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        let host = NSHostingView(rootView: Probe())
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)

        let deadline = Date().addingTimeInterval(5)
        while Self.launcherFieldEditor(in: window) == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(Self.launcherFieldEditor(in: window) != nil, "the launcher's field is not first responder")
    }
}
