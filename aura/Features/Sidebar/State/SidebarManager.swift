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

@Observable
@MainActor
final class SidebarManager {
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// The same defaults keys the old `@AppStorage` wrappers used, so the stored
    /// preferences survive the move off `@AppStorage`. `OraCommands` reads these
    /// keys directly for its menu check marks.
    private static let sidebarHiddenKey = "ui.sidebar.hidden"
    private static let sidebarPositionKey = "ui.sidebar.position"
    private static let compactEnabledKey = "ui.compact.enabled"
    private static let compactHidesKey = "ui.compact.hides"

    var isSidebarHidden: Bool {
        didSet { defaults.set(isSidebarHidden, forKey: Self.sidebarHiddenKey) }
    }

    var sidebarPosition: SidebarPosition {
        didSet { defaults.set(sidebarPosition.rawValue, forKey: Self.sidebarPositionKey) }
    }

    var isCompactEnabled: Bool {
        didSet { defaults.set(isCompactEnabled, forKey: Self.compactEnabledKey) }
    }

    var compactHides: CompactModeHides {
        didSet { defaults.set(compactHides.rawValue, forKey: Self.compactHidesKey) }
    }

    var primaryFraction = FractionHolder.usingUserDefaults(0.2, key: "ui.sidebar.fraction.primary")
    var secondaryFraction = FractionHolder.usingUserDefaults(0.2, key: "ui.sidebar.fraction.secondary")
    var hiddenSidebar = SideHolder.usingUserDefaults(key: "ui.sidebar.visibility")

    init() {
        isSidebarHidden = defaults.object(forKey: Self.sidebarHiddenKey) as? Bool ?? false
        sidebarPosition = defaults.string(forKey: Self.sidebarPositionKey)
            .flatMap(SidebarPosition.init(rawValue:)) ?? .primary
        isCompactEnabled = defaults.object(forKey: Self.compactEnabledKey) as? Bool ?? false
        compactHides = defaults.string(forKey: Self.compactHidesKey)
            .flatMap(CompactModeHides.init(rawValue:)) ?? .both
    }

    var currentFraction: FractionHolder {
        sidebarPosition == .primary ? primaryFraction : secondaryFraction
    }

    func updateSidebarHidden() {
        let hidden = hiddenSidebar.side == .primary || hiddenSidebar.side == .secondary
        guard isSidebarHidden != hidden else { return }
        isSidebarHidden = hidden
    }

    func toggleSidebar() {
        let targetSide = sidebarPosition == .primary ? SplitSide.primary : .secondary
        withAnimation(AnimationSettings.spring(response: 0.18, dampingFraction: 0.9)) {
            hiddenSidebar.side = (hiddenSidebar.side == targetSide) ? nil : targetSide
            updateSidebarHidden()
        }
    }

    func toggleSidebarPosition() {
        let isCurrentSidebarHidden = hiddenSidebar.side == (sidebarPosition == .primary ? .primary : .secondary)
        sidebarPosition = sidebarPosition == .primary ? .secondary : .primary
        if isCurrentSidebarHidden {
            hiddenSidebar.side = sidebarPosition == .primary ? .primary : .secondary
        }
    }

    // MARK: - Compact mode

    /// Compact mode keeps no visibility state of its own: it drives the existing
    /// hidden-sidebar and hidden-toolbar flags, which already hover-reveal.
    func setCompactEnabled(_ enabled: Bool, toolbar: ToolbarManager) {
        isCompactEnabled = enabled
        applyCompactMode(toolbar: toolbar)
    }

    /// Picking what compact mode takes away also turns it on: the submenu is the
    /// only place these options appear, so a silent no-op reads as a broken menu.
    func setCompactHides(_ hides: CompactModeHides, toolbar: ToolbarManager) {
        compactHides = hides
        isCompactEnabled = true
        applyCompactMode(toolbar: toolbar)
    }

    /// The hidden-sidebar and hidden-toolbar flags persist under their own keys and
    /// drift from `compactHides` between launches, so the window re-applies on open.
    func applyCompactModeIfEnabled(toolbar: ToolbarManager) {
        guard isCompactEnabled else { return }
        applyCompactMode(toolbar: toolbar)
    }

    private func applyCompactMode(toolbar: ToolbarManager) {
        let hideSidebar = isCompactEnabled && compactHides.hidesSidebar
        let hideToolbar = isCompactEnabled && compactHides.hidesToolbar
        withAnimation(AnimationSettings.easeOut(0.15)) {
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
