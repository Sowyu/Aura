import Foundation
import SwiftUI

class ToolbarManager: ObservableObject {
    @AppStorage("ui.toolbar.hidden") var isToolbarHidden: Bool = false
    @AppStorage("ui.toolbar.showfullurl") var showFullURL: Bool = true

    /// `@AppStorage` on a class property writes the default but publishes nothing,
    /// so observers are nudged by hand.
    func setHidden(_ hidden: Bool) {
        guard isToolbarHidden != hidden else { return }
        objectWillChange.send()
        isToolbarHidden = hidden
    }
}
