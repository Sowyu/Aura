import Foundation
import SwiftData

// MARK: - ContainerManager

/// Owns the `BrowsingContainer` list: creation, edits, deletion, and moving a tab from
/// one cookie jar to another. One per window, over the window's own `ModelContext`, the
/// same way `TabManager` is built.
@Observable
@MainActor
final class ContainerManager {
    let modelContext: ModelContext

    /// Bumped after every write. `containers` is a fetch, not stored state, so there is
    /// nothing for `@Observable` to track on its own: without this, a settings row added
    /// or renamed only showed up once the user clicked away and back.
    private var revision = 0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Every container, in list order.
    var containers: [BrowsingContainer] {
        _ = revision
        let descriptor = FetchDescriptor<BrowsingContainer>(
            sortBy: [SortDescriptor(\.order), SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func container(id: UUID) -> BrowsingContainer? {
        containers.first { $0.id == id }
    }

    // MARK: - Editing

    @discardableResult
    func create(
        name: String,
        colorHex: String? = nil,
        iconSymbol: String? = nil
    ) -> BrowsingContainer {
        let existing = containers
        let container = BrowsingContainer(
            name: name,
            colorHex: colorHex ?? BrowsingContainer.nextColorHex(forExisting: existing.count),
            iconSymbol: iconSymbol ?? BrowsingContainer.defaultIconSymbol,
            order: (existing.map(\.order).max() ?? -1) + 1
        )
        modelContext.insert(container)
        save()
        return container
    }

    /// A blank name is a slip, not a rename, so it is ignored the way folder renames are.
    func rename(_ container: BrowsingContainer, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        container.name = trimmed
        save()
    }

    func recolor(_ container: BrowsingContainer, hex colorHex: String) {
        container.colorHex = colorHex
        save()
    }

    func reicon(_ container: BrowsingContainer, symbol iconSymbol: String) {
        container.iconSymbol = iconSymbol
        save()
    }

    /// Tabs fall back to no container, spaces that defaulted to it stop doing so, and the
    /// store it owned is emptied. Deleting a container the user asked to delete has to
    /// take the cookies with it, otherwise a container of the same name later inherits
    /// the old logins.
    func delete(_ container: BrowsingContainer) {
        let storeIdentifier = container.storeIdentifier

        // Every tab is reassigned before the single save. Going through `move(_:to:)`
        // saved once per tab and rebuilt each web view synchronously, so deleting a
        // container with a dozen tabs froze the window.
        let orphaned = Array(container.tabs)
        for tab in orphaned {
            tab.browsingContainer = nil
        }
        for space in spaces() where space.defaultBrowsingContainer?.id == container.id {
            space.defaultBrowsingContainer = nil
        }

        modelContext.delete(container)
        save()

        // A live web view is bound to the store that is about to be emptied, so it goes
        // either way. Only a tab on screen is rebuilt; a hibernated one picks the new
        // store up when it is next restored.
        for tab in orphaned where tab.browserPage != nil {
            rebind(tab, restoring: TabManager.activeTabIDsAcrossWindows.contains(tab.id))
        }

        BrowserEngine.shared
            .makeProfile(identifier: storeIdentifier, isPrivate: false)
            .clearData(ofTypes: [.all]) {
                BrowserEngine.shared.dropProfile(identifier: storeIdentifier)
            }
    }

    /// Moves `tab` into another cookie jar. A live web view is bound to the store it was
    /// created on, so it is torn down and rebuilt on the new one, then sent back to the
    /// URL it was showing.
    func move(_ tab: Tab, to container: BrowsingContainer?) {
        guard tab.browsingContainer?.id != container?.id else { return }
        tab.browsingContainer = container
        save()

        guard tab.browserPage != nil else { return }
        rebind(tab, restoring: true)
    }

    /// Tears the web view down so it stops using the old store, and builds it again on
    /// the new one when `restoring` is set, back at the URL it was showing.
    private func rebind(_ tab: Tab, restoring: Bool) {
        let showing = tab.currentPageURL ?? tab.url
        let historyManager = tab.historyManager
        let downloadManager = tab.downloadManager
        let tabManager = tab.tabManager
        tab.destroyWebView()

        guard restoring,
              let historyManager,
              let downloadManager,
              let tabManager
        else { return }

        tab.restoreTransientState(
            historyManager: historyManager,
            downloadManager: downloadManager,
            tabManager: tabManager,
            isPrivate: tab.isPrivate,
            loading: showing
        )
    }

    /// Which container new tabs in `space` land in. `nil` is Firefox's "No container".
    func setDefault(_ container: BrowsingContainer?, for space: TabContainer) {
        space.defaultBrowsingContainer = container
        save()
    }

    /// Deals `order` back out in the given arrangement, so the values stay dense and no
    /// two rows tie.
    func reorder(_ ordered: [BrowsingContainer]) {
        for (position, container) in ordered.enumerated() {
            container.order = position
        }
        save()
    }

    func move(_ container: BrowsingContainer, to index: Int) {
        var ordered = containers
        guard let from = ordered.firstIndex(where: { $0.id == container.id }),
              ordered.indices.contains(index)
        else { return }
        ordered.remove(at: from)
        ordered.insert(container, at: index)
        reorder(ordered)
    }

    // MARK: - Migration

    /// Set once the space stores have been turned into containers.
    static let migrationDefaultsKey = "aura.browsingContainers.migratedSpaceStores"

    /// Spaces used to be the cookie jars: every tab in a space browsed on a
    /// `WKWebsiteDataStore` keyed by the space's own id. This gives each space a
    /// container holding that exact store identifier and puts the space's tabs in it, so
    /// the split between spaces and containers costs nobody a login.
    ///
    /// `defaults` is a parameter so tests can replay the migration on a scratch domain.
    static func migrateSpaceStoresIfNeeded(
        context: ModelContext,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: migrationDefaultsKey) else { return }

        let descriptor = FetchDescriptor<TabContainer>(
            sortBy: [SortDescriptor(\.order), SortDescriptor(\.createdAt)]
        )
        let spaces = (try? context.fetch(descriptor)) ?? []

        for (index, space) in spaces.enumerated() where space.defaultBrowsingContainer == nil {
            let container = BrowsingContainer(
                name: space.name,
                colorHex: space.iconColorHex ?? BrowsingContainer.nextColorHex(forExisting: index),
                iconSymbol: space.iconSymbol ?? BrowsingContainer.defaultIconSymbol,
                order: index,
                storeIdentifier: space.id
            )
            context.insert(container)
            space.defaultBrowsingContainer = container
            for tab in space.tabs where tab.browsingContainer == nil {
                tab.browsingContainer = container
            }
        }

        // Marked done only once the work is on disk; a crash mid-way replays it, and the
        // loop skips spaces that already have a default so the replay is harmless.
        do {
            try context.save()
            defaults.set(true, forKey: migrationDefaultsKey)
        } catch {
            AuraLog.category("Containers").error("Space store migration failed: \(error)")
        }
    }

    // MARK: - Private

    private func save() {
        saveOrLog(modelContext)
        revision += 1
    }

    private func spaces() -> [TabContainer] {
        (try? modelContext.fetch(FetchDescriptor<TabContainer>())) ?? []
    }
}
