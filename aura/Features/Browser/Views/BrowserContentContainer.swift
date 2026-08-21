import SwiftUI

/// Inset between the window chrome and the rounded content pane, all four sides.
let browserContentInset: CGFloat = 8

/// Gap under the toolbar row. Zero: the row already leaves `TopToolbar.verticalSlack`
/// (4pt) empty below the address pill, and that slack is the whole gap. Anything added
/// here stacks on top of it and pushes the pill off centre between the window edge and
/// the pane.
let browserContentTopInset: CGFloat = 0

/// Radius of every card the window draws: the content pane and the revealed sidebar.
let browserContentCornerRadius: CGFloat = {
    if #available(macOS 26, *) {
        return 13
    } else {
        return 6
    }
}()

struct BrowserContentContainer<Content: View>: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(AppState.self) private var appState
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(ToolbarManager.self) private var toolbarManager

    let content: () -> Content

    /// A revealed row counts as up: it occupies the same 38pt the pinned one does, so
    /// the pane sits under it exactly as it does in the pinned layout.
    private var isToolbarRowUp: Bool {
        !toolbarManager.isToolbarHidden || toolbarManager.isFloatingToolbarVisible
    }

    /// Edge-to-edge only when nothing is on screen above it. Whether the chrome went away
    /// through compact mode or by hand makes no difference to the pane.
    private var isCompleteFullscreen: Bool {
        appState.isFullscreen && sidebarManager.isSidebarHidden && !isToolbarRowUp
    }

    private var cornerRadius: CGFloat { browserContentCornerRadius }

    /// Without the row above, the pane owns the whole gap again.
    private var topInset: CGFloat {
        isToolbarRowUp ? browserContentTopInset : browserContentInset
    }

    init(
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: isCompleteFullscreen ? 0 : cornerRadius, style: .continuous))
            .padding(.top, isCompleteFullscreen ? 0 : topInset)
            .padding(.horizontal, isCompleteFullscreen ? 0 : browserContentInset)
            .padding(.bottom, isCompleteFullscreen ? 0 : browserContentInset)
            .animation(AnimationSettings.easeOut(0.15), value: appState.isFullscreen)
            .animation(AnimationSettings.easeOut(0.15), value: isToolbarRowUp)
            .shadow(color: .black.opacity(0.15), radius: isCompleteFullscreen ? 0 : cornerRadius, x: 0, y: 2)
            .ignoresSafeArea(.all)
    }
}
