import SwiftUI

/// The sidebar as a card, used while it is hover-revealed. Same fill, same radius and
/// same inset as the content pane, so the revealed sidebar reads as the pinned one
/// lifted off the window rather than as a panel of its own.
struct FloatingSidebar: View {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: browserContentCornerRadius, style: .continuous)
    }

    var body: some View {
        SidebarView()
            // The window backdrop, not a panel material: the pinned sidebar has no fill
            // of its own and shows this exact surface through.
            .auraGlassWindowBackdrop(cornerRadius: browserContentCornerRadius)
            .clipShape(shape)
            .auraFloatingShadow()
            .padding(browserContentInset)
    }
}
