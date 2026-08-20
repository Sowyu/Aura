import Foundation
import SwiftUI

class ToolbarManager: ObservableObject {
    @AppStorage("ui.toolbar.hidden") var isToolbarHidden: Bool = false
    @AppStorage("ui.toolbar.showfullurl") var showFullURL: Bool = true

    /// Compact mode's hover-revealed toolbar row. `WindowAccessor` watches it so the
    /// native traffic lights come back with the row and leave with it.
    @Published var isFloatingToolbarVisible: Bool = false

    /// `@AppStorage` on a class property writes the default but publishes nothing,
    /// so observers are nudged by hand.
    func setHidden(_ hidden: Bool) {
        guard isToolbarHidden != hidden else { return }
        objectWillChange.send()
        isToolbarHidden = hidden
    }
}
