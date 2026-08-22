import SwiftUI

struct BrowserSplitView: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(AppState.self) private var appState
    @Environment(ToolbarManager.self) private var toolbarManager
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(ToastManager.self) private var toastManager

    private var splitFraction: FractionHolder {
        sidebarManager.currentSplitFraction
    }

    /// The same bounds the revealed sidebar clamps to, so dragging the pinned splitter
    /// and dragging the revealed sidebar's handle land on the same widths.
    private var minSidebar: CGFloat { FloatingSidebarOverlay.minFraction }
    private var minContent: CGFloat { 1 - FloatingSidebarOverlay.maxFraction }

    private var minPF: CGFloat {
        sidebarManager.sidebarPosition == .primary ? minSidebar : minContent
    }

    private var minSF: CGFloat {
        sidebarManager.sidebarPosition == .primary ? minContent : minSidebar
    }

    private var prioritySide: SplitSide {
        sidebarManager.sidebarPosition == .primary ? .primary : .secondary
    }

    private var dragToHidePFlag: Bool {
        sidebarManager.sidebarPosition == .primary
    }

    private var dragToHideSFlag: Bool {
        sidebarManager.sidebarPosition == .secondary
    }

    var body: some View {
        HSplit(left: { primaryPane() }, right: { secondaryPane() })
            .hide(sidebarManager.hiddenSidebar)
            .splitter { Splitter.invisible() }
            .fraction(splitFraction)
            .constraints(
                minPFraction: minPF,
                minSFraction: minSF,
                priority: prioritySide,
                dragToHideP: dragToHidePFlag,
                dragToHideS: dragToHideSFlag
            )
            .styling(hideSplitter: true)
    }

    private func primaryPane() -> some View {
        paneContent(
            isSidebarPane: sidebarManager.sidebarPosition == .primary,
            isOtherPaneHidden: sidebarManager.hiddenSidebar.side == .secondary
        )
    }

    private func secondaryPane() -> some View {
        paneContent(
            isSidebarPane: sidebarManager.sidebarPosition == .secondary,
            isOtherPaneHidden: sidebarManager.hiddenSidebar.side == .primary
        )
    }

    @ViewBuilder
    private func paneContent(isSidebarPane: Bool, isOtherPaneHidden: Bool) -> some View {
        if isSidebarPane, !isOtherPaneHidden {
            SidebarView()
        } else {
            contentView()
        }
    }

    private func contentView() -> some View {
        Group {
            if let activeTab = tabManager.activeTab {
                BrowserContentContainer {
                    BrowserWebContentView(tab: activeTab)
                }
            } else {
                BrowserContentContainer {
                    HomePageView()
                }
            }
        }
        .toast(manager: toastManager)
    }
}
