import SwiftUI

/// Inset between the window chrome and the rounded content pane, all four sides.
let browserContentInset: CGFloat = 8

struct BrowserContentContainer<Content: View>: View {
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sidebarManager: SidebarManager

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

    init(
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: isCompleteFullscreen ? 0 : cornerRadius, style: .continuous))
            // Equal on all four sides: the toolbar now sits above the pane, so
            // the top edge no longer compensates for an in-pane URL bar.
            .padding(isCompleteFullscreen ? 0 : browserContentInset)
            .animation(.easeInOut(duration: 0.15), value: appState.isFullscreen)
            .shadow(color: .black.opacity(0.15), radius: isCompleteFullscreen ? 0 : cornerRadius, x: 0, y: 2)
            .ignoresSafeArea(.all)
    }
}
