import SwiftUI

/// "Liquid Glass (experimental)": the sidebar and the top toolbar drop their solid
/// backgrounds for a tinted translucent one. The content pane never changes, so the page
/// itself stays fully opaque and readable.
enum AuraGlass {
    static let enabledKey = "ui.glass.enabled"
    static let tintKey = "ui.glass.tintHex"
    static let defaultTintHex = "#4DABF7"

    /// Weight of the tint sitting over `.ultraThinMaterial` before macOS 26.
    static let fallbackTintOpacity: Double = 0.35

    /// Chrome text and icons flip to white or black depending on how bright the tint is.
    static func foreground(forTintHex hex: String) -> Color {
        URLBarColors.foreground(for: Color(hex: hex))
    }
}

private struct GlassChromeBackground: ViewModifier {
    @AppStorage(AuraGlass.enabledKey) private var enabled = false
    @AppStorage(AuraGlass.tintKey) private var tintHex = AuraGlass.defaultTintHex
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if enabled {
            content
                .environment(\.theme, theme.withForeground(AuraGlass.foreground(forTintHex: tintHex)))
                .background { AuraGlassSurface(tint: Color(hex: tintHex)) }
        } else {
            content
        }
    }
}

/// The translucent layer itself, also used for the settings preview.
struct AuraGlassSurface: View {
    let tint: Color

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(tint), in: .rect)
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(tint.opacity(AuraGlass.fallbackTintOpacity))
        }
    }
}

extension View {
    /// Sidebar and top toolbar only. A no-op while the setting is off.
    func auraGlassChrome() -> some View {
        modifier(GlassChromeBackground())
    }
}
