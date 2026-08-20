import SwiftUI

/// Hover highlight + press feedback for every icon/chrome button in the app.
/// 80 ms is deliberate: slow enough to read as motion, fast enough to feel instant.
struct InteractiveButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var hoverOpacity: Double = 0.10
    var pressOpacity: Double = 0.18
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        // The body lives in a real View so `@State` gets storage; SwiftUI does not
        // reliably hand a ButtonStyle struct its own state.
        HoverBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            hoverOpacity: hoverOpacity,
            pressOpacity: pressOpacity,
            tint: tint
        )
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let hoverOpacity: Double
        let pressOpacity: Double
        let tint: Color

        @State private var isHovering = false

        var body: some View {
            let opacity = configuration.isPressed ? pressOpacity : (isHovering ? hoverOpacity : 0)
            configuration.label
                .background(tint.opacity(opacity), in: .rect(cornerRadius: cornerRadius))
                .contentShape(.rect(cornerRadius: cornerRadius))
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.08), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}

extension ButtonStyle where Self == InteractiveButtonStyle {
    static var interactive: InteractiveButtonStyle { InteractiveButtonStyle() }
    static func interactive(cornerRadius: CGFloat = 6, tint: Color = .primary) -> InteractiveButtonStyle {
        InteractiveButtonStyle(cornerRadius: cornerRadius, tint: tint)
    }
}

/// Click feedback for rows that cannot be a `Button`: drag sources and context-menu
/// hosts, where a `DragGesture(minimumDistance: 0)` would swallow the row's own
/// `.onDrag`. Flashes a scale dip instead of tracking a real press.
struct TapFlash: ViewModifier {
    let scale: CGFloat
    let action: () -> Void

    @State private var isPressed = false

    private static let duration: TimeInterval = 0.09

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? scale : 1)
            .animation(.easeOut(duration: Self.duration), value: isPressed)
            .onTapGesture {
                isPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { isPressed = false }
                action()
            }
    }
}

extension View {
    func tapFlash(scale: CGFloat = 0.97, perform action: @escaping () -> Void) -> some View {
        modifier(TapFlash(scale: scale, action: action))
    }
}
