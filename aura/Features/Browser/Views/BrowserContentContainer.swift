import SwiftUI

/// Inset between the window chrome and the rounded content pane, all four sides.
let browserContentInset: CGFloat = 8

/// Top-up applied under the toolbar row. The row already leaves
/// `TopToolbar.verticalSlack` empty below the address pill, so anything sitting
/// under it only adds the remainder to reach `browserContentInset` of visible gap.
var browserContentTopInset: CGFloat {
    max(browserContentInset - TopToolbar.verticalSlack, 0)
}

struct BrowserContentContainer<Content: View>: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sidebarManager: SidebarManager
    @EnvironmentObject var toolbarManager: ToolbarManager

    let content: () -> Content

    private var isCompleteFullscreen: Bool {
        appState.isFullscreen && sidebarManager.isSidebarHidden
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
