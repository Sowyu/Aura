import SwiftData
import SwiftUI

@MainActor
extension TabManager {
    /// Only the first `TabManager` in the process runs this: every window shares one
    /// store, so a second pass would close the tabs the first window just kept.
    /// Internal so tests can replay a launch.
    static var didApplyLaunchPolicy = false

    /// Whether the run before this one ended in a crash. Read once, lazily, so the marker
    /// this run leaves behind is written whoever asks first; a test replaying a launch can
    /// set it either way.
    ///
    /// The unit-test host is this same app and XCTest kills it rather than quitting it,
    /// so under test the answer is a flat no: otherwise every run after the first would
    /// read as a crash and hold back the policy the tests are replaying.
    static var previousRunCrashed: Bool = {
        guard !SessionMarker.isTestHost else { return false }
        return SessionMarker.shared.beginSession() == .crashed
    }()

    /// Set when a crash held the policy back. The user's answer to the restore bar is
    /// what spends it.
    static var deferredLaunchPolicy = false

    /// Whether this manager's store is the one the launch policy is about: the on-disk
    /// store every normal window shares, never a private window's in-memory copy.
    ///
    /// The unit-test host runs every manager in memory and replays launches on purpose,
    /// the same reason `previousRunCrashed` answers no under test. The flag is a
    /// parameter so the rule itself can be checked without one.
    static func ownsLaunchPolicy(
        isInMemoryStore: Bool,
        isTestHost: Bool = SessionMarker.isTestHost
    ) -> Bool {
        !isInMemoryStore || isTestHost
    }

    /// "Reopen the tabs I had open" off means the saved normal tabs are dropped at
    /// launch. Pinned and favourite tabs always come back.
    ///
    /// After a crash those saved tabs are the only copy of the session the user lost, so
    /// the policy waits: the tabs stay, the restore bar goes up, and dropping them is
    /// what dismissing it does. Deferring rather than snapshotting them into the reopen
    /// stack, because that stack holds five and a crashed window can hold fifty.
    func applyLaunchTabPolicy() {
        // A private window's store is its own empty in-memory one, and it can be built
        // before the first normal window: spending the once-per-launch flag there would
        // leave the saved tabs this policy is about sitting on disk untouched.
        guard Self.ownsLaunchPolicy(
            isInMemoryStore: modelContainer.configurations.first?.isStoredInMemoryOnly == true
        ) else { return }
        guard !Self.didApplyLaunchPolicy else { return }
        Self.didApplyLaunchPolicy = true
        guard !SettingsStore.shared.restoreTabsOnLaunch else { return }

        if Self.previousRunCrashed, hasSavedNormalTabs {
            Self.deferredLaunchPolicy = true
            offersSessionRestore = true
            return
        }
        dropSavedNormalTabs()
    }

    /// Keep the crashed run's tabs. The policy is spent for this launch, so the next
    /// ordinary quit is the next time it applies.
    func keepPreviousSession() {
        offersSessionRestore = false
        Self.deferredLaunchPolicy = false
    }

    /// The user does not want them back, so the policy runs now, late.
    func discardPreviousSession() {
        offersSessionRestore = false
        guard Self.deferredLaunchPolicy else { return }
        Self.deferredLaunchPolicy = false
        dropSavedNormalTabs()
    }

    private var hasSavedNormalTabs: Bool {
        fetchContainers().contains { container in
            container.tabs.contains { $0.type == .normal }
        }
    }

    private func dropSavedNormalTabs() {
        // Launch time: no web views, no media, nothing to track for reopen. Delete directly
        // and synchronously; `closeTab` finishes on an async hop that holds `self` weakly,
        // which a short-lived manager (tests, a window closed at once) never reaches.
        // No fetch-first guard either: this runs once, from the first manager in the
        // process, so there is no second context to race with.
        var deleted: [UUID] = []
        for container in fetchContainers() {
            for tab in Array(container.tabs) where tab.type == .normal {
                mediaController.removeSession(for: tab.id)
                // Adapters are pruned nowhere else on this path, and WebKit would keep
                // reporting every dropped tab as open for the rest of the session.
                ExtensionManager.shared.tabDidClose(tab)
                deleted.append(tab.id)
                modelContext.delete(tab)
            }
        }
        saveOrLog(modelContext)
        announceDeletedTabs(deleted)
    }
}
