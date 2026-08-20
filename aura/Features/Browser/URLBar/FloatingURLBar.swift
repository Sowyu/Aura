import SwiftUI

struct FloatingURLBar: View {
    @Environment(AppState.self) private var appState

    @Binding var showFloatingURLBar: Bool
    @Binding var isMouseOverURLBar: Bool

    /// Depth of the bar once it is out; the band that arms it is 12pt at the edge.
    private static let revealedHeight: CGFloat = 50

    var body: some View {
        ZStack(alignment: .top) {
            if showFloatingURLBar {
                URLBar(
                    onSidebarToggle: {
                        NotificationCenter.default.post(
                            name: .toggleSidebar, object: nil
                        )
                    }
                )
                .shadow(color: Color.black.opacity(0.2), radius: 10, y: 4)
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(Color(.separatorColor)),
                    alignment: .bottom
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }

            VStack(alignment: .leading) {
                hoverStrip()
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: GlobalMouseTrackingArea.hotZone)
        }
        .animation(.easeOut(duration: 0.15), value: showFloatingURLBar)
    }

    private func hoverStrip() -> some View {
        Color.clear
            .overlay(
                GlobalMouseTrackingArea(
                    mouseEntered: Binding(
                        get: { showFloatingURLBar },
                        set: { newValue in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isMouseOverURLBar = newValue
                                showFloatingURLBar = newValue
                            }
                        }
                    ),
                    edge: .top,
                    revealedExtent: Self.revealedHeight,
                    isHeld: { appState.isURLBarEditing || AuraMenuController.shared.isOpen }
                )
            )
    }
}
