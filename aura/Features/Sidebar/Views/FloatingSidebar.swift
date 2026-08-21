import SwiftUI

struct FloatingSidebar: View {
    @Environment(\.theme) var theme

    let sidebarCornerRadius: CGFloat = {
        if #available(macOS 26, *) {
            return 13
        } else {
            return 5
        }
    }()

    var body: some View {
        let clipShape = ConditionallyConcentricRectangle(cornerRadius: sidebarCornerRadius)

        ZStack(alignment: .leading) {
            SidebarView()
                // Glass clips itself to the same radius; an ancestor clipShape does not
                // reach the system's glass layer on macOS 26.
                .auraGlassChrome(cornerRadius: sidebarCornerRadius)
                .background(theme.chromeBackground)
                .background(BlurEffectView(material: .popover, blendingMode: .withinWindow))
                .clipShape(clipShape)
                .overlay(clipShape
                    .stroke(theme.invertedSolidWindowBackgroundColor.opacity(0.3), lineWidth: 1)
                )
                .padding(.top, 0)
        }
        .padding(6)
    }
}
