import AppKit
import SwiftUI

/// The single icon button used by every chrome row: top toolbar, floating URL
/// bar, sidebar header. Keeping one type is what makes them look identical.
struct URLBarButton: View {
    static let cornerRadius = AuraRadius.button
    /// One size and weight for every chrome glyph, including the few rows that draw
    /// their own `Image` instead of a `URLBarButton`. Regular at 13 reads as a quiet
    /// mark next to the address pill; medium made the arrows shout.
    static let iconSize: CGFloat = 13
    static let iconWeight: Font.Weight = .regular
    /// The one muting every chrome icon gets. Callers hand over `theme.foreground`
    /// plain, because a second opacity on the way in stacks two numbers on one icon.
    static let enabledOpacity: Double = 0.7
    static let disabledOpacity: Double = 0.35

    /// How long a press has to be held before it counts as one. macOS uses roughly this
    /// for a toolbar button's own held menu.
    static let longPressDuration: TimeInterval = 0.4

    /// Navigation marks come from the bundled toolbar SVGs; the rest stay SF Symbols.
    var icon: ToolbarIcon?
    var systemName: String = ""
    let isEnabled: Bool
    let foregroundColor: Color
    var size: CGFloat = 30
    let action: () -> Void
    /// Press and hold, used by the back and forward buttons for the tab's history menu.
    /// Nil on every other button, which is what leaves their clicks untouched.
    var longPressAction: (() -> Void)?

    /// Set when a hold fired. The release that ends the hold still reaches the button, so
    /// exactly that one click is swallowed rather than also navigating.
    @State private var didLongPress = false

    var body: some View {
        Button {
            guard !didLongPress else {
                didLongPress = false
                return
            }
            action()
        } label: {
            content
                .foregroundColor(foregroundColor.opacity(isEnabled ? Self.enabledOpacity : Self.disabledOpacity))
                .frame(width: size, height: size)
        }
        .buttonStyle(.interactive(cornerRadius: Self.cornerRadius, tint: foregroundColor))
        .disabled(!isEnabled)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: Self.longPressDuration).onEnded { _ in
                guard let longPressAction else { return }
                didLongPress = true
                longPressAction()
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if let icon {
            ToolbarIconView(icon: icon, size: 16)
        } else {
            Image(systemName: systemName)
                .font(.system(size: Self.iconSize, weight: Self.iconWeight))
        }
    }
}
