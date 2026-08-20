import Foundation
import SwiftUI

@Observable
@MainActor
final class ToolbarManager {
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Same defaults keys the old `@AppStorage` wrappers used, so the stored
    /// preference survives the move off `@AppStorage`.
    private static let hiddenKey = "ui.toolbar.hidden"
    private static let showFullURLKey = "ui.toolbar.showfullurl"

    var isToolbarHidden: Bool {
        didSet { defaults.set(isToolbarHidden, forKey: Self.hiddenKey) }
    }

    var showFullURL: Bool {
        didSet { defaults.set(showFullURL, forKey: Self.showFullURLKey) }
    }

    /// Compact mode's hover-revealed toolbar row. `WindowAccessor` watches it so the
    /// native traffic lights come back with the row and leave with it.
    var isFloatingToolbarVisible: Bool = false

    init() {
        isToolbarHidden = defaults.object(forKey: Self.hiddenKey) as? Bool ?? false
        showFullURL = defaults.object(forKey: Self.showFullURLKey) as? Bool ?? true
    }

    func setHidden(_ hidden: Bool) {
        guard isToolbarHidden != hidden else { return }
        isToolbarHidden = hidden
    }
}
