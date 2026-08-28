import SwiftUI

enum SidebarPosition: String, Hashable {
    case primary
    case secondary
}

/// What the sidebar shows in place of the spaces list. The panel slides over the spaces
/// and the spaces blur back behind it; `.none` is the ordinary sidebar.
enum SidebarPanel: String, Hashable {
    case none
    case downloads
    case history
    /// The file tray, next to downloads at the foot of the sidebar.
    case files

    var isOpen: Bool { self != .none }
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

    /// Open the sidebar's history panel. Posted by the History menu (⌘Y) and by the
    /// "…" menu's "Show All History" item. Handled in `BrowserView`.
    static let showHistoryPanel = Notification.Name("ShowHistoryPanel")

    /// Same, for the downloads panel: the "…" menu has no `SidebarManager` to set the
    /// panel on directly.
    static let showDownloadsPanel = Notification.Name("ShowDownloadsPanel")
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

    /// Not persisted: a panel is a place you are, not a preference. Reopening a window
    /// puts you back on the spaces list.
    var panel: SidebarPanel = .none

    /// Tapping the panel you are already in goes back to the spaces list.
    func togglePanel(_ target: SidebarPanel) {
        panel = panel == target ? .none : target
    }

    var primaryFraction = FractionHolder.usingUserDefaults(0.2, key: "ui.sidebar.fraction.primary")
    var secondaryFraction = FractionHolder.usingUserDefaults(0.2, key: "ui.sidebar.fraction.secondary")
    var hiddenSidebar = SideHolder.usingUserDefaults(key: "ui.sidebar.visibility")

    /// The split view measures from the left, so a sidebar on the right needs the
    /// inverted fraction. Held here because `inverted()` returns a new holder, and
    /// minting one per body evaluation gave the splitter a fresh observable object to
    /// bind to on every redraw: the drag lost its position mid-gesture.
    @ObservationIgnored private(set) lazy var invertedSecondaryFraction = secondaryFraction.inverted()

    init() {
        isSidebarHidden = defaults.object(forKey: Self.sidebarHiddenKey) as? Bool ?? false
        sidebarPosition = defaults.string(forKey: Self.sidebarPositionKey)
            .flatMap(SidebarPosition.init(rawValue:)) ?? .primary
        isCompactEnabled = defaults.object(forKey: Self.compactEnabledKey) as? Bool ?? false
        compactHides = defaults.string(forKey: Self.compactHidesKey)
            .flatMap(CompactModeHides.init(rawValue:)) ?? .both

        // The split view writes the holder itself when the splitter is dragged to hide
        // or unhide a pane, without coming through this class. `isSidebarHidden` gates
        // the hover-revealed floating sidebar, so letting it drift put a docked sidebar
        // and the floating one on screen together. Chain the holder's setter (which
        // `usingUserDefaults` already uses for persistence) so every write re-syncs.
        let persistSide = hiddenSidebar.setter
        hiddenSidebar.setter = { [weak self] side in
            persistSide?(side)
            guard let self else { return }
            MainActor.assumeIsolated { self.updateSidebarHidden() }
        }
        // The two persisted keys can disagree at launch (one write landed, the other
        // did not); reconcile before the first body evaluation reads either.
        updateSidebarHidden()
    }

    var currentFraction: FractionHolder {
        sidebarPosition == .primary ? primaryFraction : secondaryFraction
    }

    /// `currentFraction` as the split view wants it, measured from the leading edge.
    var currentSplitFraction: FractionHolder {
        sidebarPosition == .primary ? primaryFraction : invertedSecondaryFraction
    }

    func updateSidebarHidden() {
        // A stored side can name the pane the sidebar occupied before it moved, which
        // hides the content pane instead. Remap it onto the sidebar's pane; the write
        // re-enters through the holder's setter and lands in the consistent branch.
        let sidebarSide: SplitSide = sidebarPosition == .primary ? .primary : .secondary
        if let side = hiddenSidebar.side,
           side.isPrimary != sidebarSide.isPrimary {
            hiddenSidebar.side = sidebarSide
            return
        }
        let hidden = hiddenSidebar.side != nil
        guard isSidebarHidden != hidden else { return }
        isSidebarHidden = hidden
    }

    func toggleSidebar() {
        let targetSide = sidebarPosition == .primary ? SplitSide.primary : .secondary
        withAnimation(AnimationSettings.easeOut(0.15)) {
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
        guard isCompactEnabled else {
            // `isSidebarHidden` and the split's own side holder are two stored keys that
            // can disagree, and a side stored before the sidebar moved names the wrong
            // pane. Either way the sidebar goes missing with no edge to bring it back.
            setSidebarHidden(isSidebarHidden)
            return
        }
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
