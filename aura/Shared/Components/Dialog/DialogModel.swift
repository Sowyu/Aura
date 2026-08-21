import SwiftUI

struct Dialog: Identifiable {
    private(set) var id: String = UUID().uuidString
    var content: AnyView
    var onConfirm: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// The ⌘Q confirmation. Marked so a second ⌘Q can answer it: AppKit swallows
    /// `terminate:` while a `terminateLater` reply is still parked, so
    /// `applicationShouldTerminate` never runs a second time.
    var isQuitConfirmation = false

    init(@ViewBuilder content: @escaping (String) -> some View) {
        self.content = .init(content(id))
    }
}
