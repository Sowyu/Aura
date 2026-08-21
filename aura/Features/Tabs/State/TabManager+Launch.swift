import SwiftData
import SwiftUI

@MainActor
extension TabManager {
    /// Only the first `TabManager` in the process runs this: every window shares one
    /// store, so a second pass would close the tabs the first window just kept.
    /// Internal so tests can replay a launch.
    static var didApplyLaunchPolicy = false

    /// "Reopen the tabs I had open" off means the saved normal tabs are dropped at
    /// launch. Pinned and favourite tabs always come back.
    func applyLaunchTabPolicy() {
        guard !Self.didApplyLaunchPolicy else { return }
        Self.didApplyLaunchPolicy = true
        guard !SettingsStore.shared.restoreTabsOnLaunch else { return }

        // Launch time: no web views, no media, nothing to track for reopen. Delete directly
        // and synchronously; `closeTab` finishes on an async hop that holds `self` weakly,
        // which a short-lived manager (tests, a window closed at once) never reaches.
        for container in fetchContainers() {
            for tab in Array(container.tabs) where tab.type == .normal {
                mediaController.removeSession(for: tab.id)
                modelContext.delete(tab)
            }
        }
        try? modelContext.save()
    }
}
