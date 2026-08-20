import SwiftUI

enum SidebarPosition: String, Hashable {
    case primary
    case secondary
}

/// Which chrome compact mode takes away while it is on.
enum CompactModeHides: String, Hashable, CaseIterable {
    case sidebar
    case toolbar
    case both

    var hidesSidebar: Bool { self != .toolbar }
    var hidesToolbar: Bool { self != .sidebar }

    var menuTitle: String {
        switch self {
        case .sidebar: return "Hide sidebar"
        case .toolbar: return "Hide toolbar"
        case .both: return "Hide both"
        }
    }
}

extension Notification.Name {
    /// View menu → `BrowserView` flips compact mode.
    /// `newTabFolder` lives in `TabNotifications.swift`, posted by the sidebar context menu.
    static let toggleCompactMode = Notification.Name("ToggleCompactMode")
}

@MainActor
class SidebarManager: ObservableObject {
    @AppStorage("ui.sidebar.hidden") var isSidebarHidden: Bool = false
    @AppStorage("ui.sidebar.position") var sidebarPosition: SidebarPosition = .primary
    @AppStorage("ui.compact.enabled") var isCompactEnabled: Bool = false
    @AppStorage("ui.compact.hides") var compactHides: CompactModeHides = .both

    @Published var primaryFraction = FractionHolder.usingUserDefaults(0.2, key: "ui.sidebar.fraction.primary")
    @Published var secondaryFraction = FractionHolder.usingUserDefaults(0.2, key: "ui.sidebar.fraction.secondary")
    @Published var hiddenSidebar = SideHolder.usingUserDefaults(key: "ui.sidebar.visibility")

    var currentFraction: FractionHolder {
        sidebarPosition == .primary ? primaryFraction : secondaryFraction
    }

    func updateSidebarHidden() {
        isSidebarHidden = hiddenSidebar.side == .primary || hiddenSidebar.side == .secondary
    }

    func toggleSidebar() {
        let targetSide = sidebarPosition == .primary ? SplitSide.primary : .secondary
        withAnimation(.spring(response: 0.18, dampingFraction: 0.9)) {
            hiddenSidebar.side = (hiddenSidebar.side == targetSide) ? nil : targetSide
            updateSidebarHidden()
        }
    }

    func toggleSidebarPosition() {
        let isCurrentSidebarHidden = hiddenSidebar.side == (sidebarPosition == .primary ? .primary : .secondary)
        objectWillChange.send()
        sidebarPosition = sidebarPosition == .primary ? .secondary : .primary
        if isCurrentSidebarHidden {
            hiddenSidebar.side = sidebarPosition == .primary ? .primary : .secondary
        }
    }

    // MARK: - Compact mode

    /// Compact mode keeps no visibility state of its own: it drives the existing
    /// hidden-sidebar and hidden-toolbar flags, which already hover-reveal.
    func setCompactEnabled(_ enabled: Bool, toolbar: ToolbarManager) {
        objectWillChange.send()
        isCompactEnabled = enabled
        applyCompactMode(toolbar: toolbar)
    }

    func setCompactHides(_ hides: CompactModeHides, toolbar: ToolbarManager) {
        objectWillChange.send()
        compactHides = hides
        applyCompactMode(toolbar: toolbar)
    }

    private func applyCompactMode(toolbar: ToolbarManager) {
        let hideSidebar = isCompactEnabled && compactHides.hidesSidebar
        let hideToolbar = isCompactEnabled && compactHides.hidesToolbar
        withAnimation(.easeOut(duration: 0.15)) {
            setSidebarHidden(hideSidebar)
            toolbar.setHidden(hideToolbar)
        }
    }

    private func setSidebarHidden(_ hidden: Bool) {
        let targetSide: SplitSide = sidebarPosition == .primary ? .primary : .secondary
        hiddenSidebar.side = hidden ? targetSide : nil
        updateSidebarHidden()
    }
}
