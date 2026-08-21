import SwiftData
import SwiftUI

@MainActor
extension TabManager {
    /// Only the first `TabManager` in the process runs this: every window shares one
    /// store, so a second pass would close the tabs the first window just kept.
    private static var didApplyLaunchPolicy = false

    /// "Reopen the tabs I had open" off means the saved normal tabs are dropped at
    /// launch. Pinned and favourite tabs always come back.
    func applyLaunchTabPolicy() {
        guard !Self.didApplyLaunchPolicy else { return }
        Self.didApplyLaunchPolicy = true
        guard !SettingsStore.shared.restoreTabsOnLaunch else { return }

        for container in fetchContainers() {
            for tab in container.tabs where tab.type == .normal {
                closeTab(tab: tab, shouldTrackForRestore: false)
            }
        }
    }
}
