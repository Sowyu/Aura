import SwiftUI

/// Inset between the window chrome and the rounded content pane, all four sides.
let browserContentInset: CGFloat = 8

/// Gap under the toolbar row. Half `browserContentInset`, because the row already
/// leaves `TopToolbar.verticalSlack` (4pt) empty below the address pill and the two
/// together read as the same 8pt the other three sides use.
let browserContentTopInset: CGFloat = 4

struct BrowserContentContainer<Content: View>: View {
    @Environment(TabManager.self) private var tabManager
    @Environment(AppState.self) private var appState
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(ToolbarManager.self) private var toolbarManager

    let content: () -> Content

    /// Edge-to-edge only in plain fullscreen. Compact mode keeps the inset and rounded
    /// corners so the revealed chrome has somewhere to slide over.
    private var isCompleteFullscreen: Bool {
        appState.isFullscreen && sidebarManager.isSidebarHidden && !sidebarManager.isCompactEnabled
    }

    private var cornerRadius: CGFloat {
        if #available(macOS 26, *) {
            return 13
        } else {
            return 6
        }
    }

    /// Without the row above, the pane owns the whole gap again.
    private var topInset: CGFloat {
        toolbarManager.isToolbarHidden ? browserContentInset : browserContentTopInset
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
            .animation(.easeInOut(duration: 0.15), value: appState.isFullscreen)
            .shadow(color: .black.opacity(0.15), radius: isCompleteFullscreen ? 0 : cornerRadius, x: 0, y: 2)
            .ignoresSafeArea(.all)
    }
}
