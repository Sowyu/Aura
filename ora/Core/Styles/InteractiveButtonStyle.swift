import SwiftUI

/// Hover highlight + press feedback for every icon/chrome button in the app.
/// 80 ms is deliberate: slow enough to read as motion, fast enough to feel instant.
struct InteractiveButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var hoverOpacity: Double = 0.10
    var pressOpacity: Double = 0.18
    var tint: Color = .primary

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
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

extension ButtonStyle where Self == InteractiveButtonStyle {
    static var interactive: InteractiveButtonStyle { InteractiveButtonStyle() }
    static func interactive(cornerRadius: CGFloat = 6, tint: Color = .primary) -> InteractiveButtonStyle {
        InteractiveButtonStyle(cornerRadius: cornerRadius, tint: tint)
    }
}
