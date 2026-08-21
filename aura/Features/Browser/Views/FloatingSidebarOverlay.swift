import SwiftUI

struct FloatingSidebarOverlay: View {
    static let minFraction: CGFloat = 0.10
    static let maxFraction: CGFloat = 0.30

    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(AppState.self) private var appState

    @Binding var showFloatingSidebar: Bool
    @Binding var isMouseOverSidebar: Bool

    var sidebarFraction: FractionHolder
    let isDownloadsOpen: Bool

    @State private var dragFraction: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let minFraction = Self.minFraction
            let maxFraction = Self.maxFraction
            let currentFraction = dragFraction ?? sidebarFraction.value
            let clampedFraction = min(max(currentFraction, minFraction), maxFraction)
            let floatingWidth = max(0, min(totalWidth * clampedFraction, totalWidth))

            ZStack(alignment: sidebarManager.sidebarPosition == .primary ? .leading : .trailing) {
                if showFloatingSidebar {
                    FloatingSidebar()
                        .frame(width: floatingWidth)
                        .transition(.move(edge: sidebarManager.sidebarPosition == .primary ? .leading : .trailing))
                        .overlay(alignment: sidebarManager.sidebarPosition == .primary ? .trailing : .leading) {
                            ResizeHandle(
                                dragFraction: $dragFraction,
                                sidebarFraction: sidebarFraction,
                                sidebarPosition: sidebarManager.sidebarPosition,
                                floatingWidth: floatingWidth,
                                totalWidth: totalWidth,
                                minFraction: minFraction,
                                maxFraction: maxFraction
                            )
                        }
                        .zIndex(3)
                }

                HStack(spacing: 0) {
                    if sidebarManager.sidebarPosition == .primary {
                        hoverStrip(revealedWidth: floatingWidth)
                        Spacer()
                    } else {
                        Spacer()
                        hoverStrip(revealedWidth: floatingWidth)
                    }
                }
                .zIndex(2)
            }
        }
    }

    /// Downloads, an open menu, the launcher and a live URL edit all keep the sidebar
    /// out no matter where the pointer went.
    private var isHeld: Bool {
        isDownloadsOpen || AuraMenuController.shared.isOpen
            || appState.showLauncher || appState.isURLBarEditing
    }

    /// The band that arms the reveal is 12pt at the window edge; once the sidebar is
    /// out, the whole column it occupies keeps it out.
    private func hoverStrip(revealedWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: GlobalMouseTrackingArea.hotZone)
            // The band only reads the pointer; a click in it belongs to the page.
            .allowsHitTesting(false)
            .overlay(
                GlobalMouseTrackingArea(
                    mouseEntered: Binding(
                        get: { showFloatingSidebar },
                        set: { newValue in
                            isMouseOverSidebar = newValue
                            showFloatingSidebar = newValue
                        }
                    ),
                    edge: sidebarManager.sidebarPosition == .primary ? .left : .right,
                    revealedExtent: revealedWidth,
                    isHeld: { isHeld }
                )
            )
    }
}

private struct ResizeHandle: View {
    @Binding var dragFraction: CGFloat?
    var sidebarFraction: FractionHolder
    let sidebarPosition: SidebarPosition
    let floatingWidth: CGFloat
    let totalWidth: CGFloat
    let minFraction: CGFloat
    let maxFraction: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 14)
        #if targetEnvironment(macCatalyst) || os(macOS)
            .cursor(NSCursor.resizeLeftRight)
        #endif
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let proposedWidth: CGFloat = if sidebarPosition == .primary {
                            max(0, min(floatingWidth + value.translation.width, totalWidth))
                        } else {
                            max(0, min(floatingWidth - value.translation.width, totalWidth))
                        }

                        let newFraction = proposedWidth / max(totalWidth, 1)
                        dragFraction = min(max(newFraction, minFraction), maxFraction)
                    }
                    .onEnded { _ in
                        if let fraction = dragFraction {
                            sidebarFraction.value = fraction
                        }
                        dragFraction = nil
                    }
            )
    }
}
