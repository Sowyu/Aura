//
//  TabDropCommit.swift
//  Aura
//
//  The commit half of Nook's drop handling (SpaceView.handlePendingDrop,
//  github.com/nook-browser/nook, GPL-3.0), rewritten against Aura's `order` scale.
//  Nook moves a tab to an index; Aura hands the target row to `reorderTabs`.
//

import AppKit
import SwiftData
import SwiftUI

@MainActor
enum TabDropCommit {
    /// Applies a released drag. Runs once, in the space that owns the target zone.
    static func apply(_ drop: PendingTabDrop, in container: TabContainer, tabManager: TabManager) {
        if let folder = container.folders.first(where: { $0.id == drop.draggedID }) {
            // Folder rows only reorder against each other, and only inside their space.
            guard case let .between(indicator) = drop.target,
                  let target = container.folders.first(where: { $0.id == indicator.targetID })
            else { return }
            withAnimation(AnimationSettings.easeOut(0.15)) {
                tabManager.move(folder: folder, to: target)
            }
            return
        }

        guard let tab = tab(drop.draggedID, in: container, tabManager: tabManager) else { return }
        // A tab dragged in from another space has to change space first, otherwise it
        // keeps rendering in the one it came from.
        if tab.container.id != container.id {
            tab.folder = nil
            tab.container = container
        }

        switch drop.target {
        case let .intoFolder(folderID):
            guard let folder = container.folders.first(where: { $0.id == folderID }) else { return }
            withAnimation(AnimationSettings.easeOut(0.15)) {
                tabManager.move(tab: tab, to: folder)
            }
        case let .between(indicator):
            guard let target = container.tabs.first(where: { $0.id == indicator.targetID }), target.id != tab.id
            else { return }
            place(tab, next: target, below: indicator.below, tabManager: tabManager)
        case .emptySection:
            fill(drop.zone.section, with: tab, in: container, tabManager: tabManager)
        }
    }

    // MARK: - Cases

    private static func place(_ tab: Tab, next target: Tab, below: Bool, tabManager: TabManager) {
        guard isInSameSection(from: tab, to: target) else {
            withAnimation(AnimationSettings.easeOut(0.15)) {
                moveTabBetweenSections(from: tab, to: target)
            }
            try? tabManager.modelContext.save()
            return
        }
        // A tab dropped next to another one joins that tab's folder, which is also how a
        // child leaves a folder: the target is top level.
        if tab.type == .normal, tab.folder?.id != target.folder?.id {
            tab.folder = target.folder
            target.folder?.isCollapsed = false
        }
        withAnimation(AnimationSettings.easeOut(0.15)) {
            target.container.reorderTabs(from: tab, to: target, placeBelow: below)
        }
        try? tabManager.modelContext.save()
    }

    /// Dropping into a section with no rows of its own: retype the tab and put it on top.
    private static func fill(
        _ section: TabSection,
        with tab: Tab,
        in container: TabContainer,
        tabManager: TabManager
    ) {
        let type = tabType(for: section)
        guard tab.type != type || tab.folder != nil else { return }
        withAnimation(AnimationSettings.easeOut(0.15)) {
            tab.type = type
            switch type {
            case .pinned, .fav:
                // Same rule as `switchSections`: an already-pinned tab carries its
                // pinned URL across tiers, a normal tab adopts its current address.
                if tab.savedURL == nil { tab.savedURL = tab.url }
                // Only normal tabs live in folders.
                tab.folder = nil
            case .normal:
                tab.savedURL = nil
                tab.folder = nil
            }
            let orders = container.tabs.map(\.order) + container.folders.map(\.order)
            tab.order = (orders.max() ?? 0) + 1
        }
        try? tabManager.modelContext.save()
    }

    /// The drag may have started in another space, whose tabs are not in this container.
    private static func tab(_ id: UUID, in container: TabContainer, tabManager: TabManager) -> Tab? {
        if let match = container.tabs.first(where: { $0.id == id }) { return match }
        let descriptor = FetchDescriptor<Tab>(predicate: #Predicate { $0.id == id })
        return try? tabManager.modelContext.fetch(descriptor).first
    }
}
