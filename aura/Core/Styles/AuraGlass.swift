import SwiftUI

/// "Liquid Glass (experimental)": the sidebar and the top toolbar drop their solid
/// backgrounds for a tinted translucent one. The content pane never changes, so the page
/// itself stays fully opaque and readable.
enum AuraGlass {
    static let enabledKey = "ui.glass.enabled"
    static let tintKey = "ui.glass.tintHex"
    static let opacityKey = "ui.glass.opacity"
    static let defaultTintHex = "#4DABF7"

    /// How much of the tint covers the glass: 0 leaves it clear, 1 makes it a solid fill.
    static let defaultOpacity: Double = 0.35

    /// Chrome text and icons flip to white or black depending on how bright the chrome
    /// ends up, which is the tint blended over whatever shows through at that opacity.
    static func foreground(forTintHex hex: String, opacity: Double, colorScheme: ColorScheme) -> Color {
        URLBarColors.foreground(for: blended(tintHex: hex, opacity: opacity, colorScheme: colorScheme))
    }

    /// The tint laid over the window's own background for the current appearance.
    static func blended(tintHex: String, opacity: Double, colorScheme: ColorScheme) -> Color {
        let base = NSColor(Theme(colorScheme: colorScheme).background)
        let tint = NSColor(Color(hex: tintHex))
        guard let baseRGB = base.usingColorSpace(.sRGB), let tintRGB = tint.usingColorSpace(.sRGB) else {
            return Color(hex: tintHex)
        }
        let amount = min(max(opacity, 0), 1)
        return Color(
            red: Double(baseRGB.redComponent + (tintRGB.redComponent - baseRGB.redComponent) * amount),
            green: Double(baseRGB.greenComponent + (tintRGB.greenComponent - baseRGB.greenComponent) * amount),
            blue: Double(baseRGB.blueComponent + (tintRGB.blueComponent - baseRGB.blueComponent) * amount)
        )
    }
}

private struct GlassChromeBackground: ViewModifier {
    @AppStorage(AuraGlass.enabledKey) private var enabled = false
    @AppStorage(AuraGlass.tintKey) private var tintHex = AuraGlass.defaultTintHex
    @AppStorage(AuraGlass.opacityKey) private var tintOpacity = AuraGlass.defaultOpacity
    @Environment(\.theme) private var theme

    private var chromeForeground: Color {
        AuraGlass.foreground(forTintHex: tintHex, opacity: tintOpacity, colorScheme: theme.colorScheme)
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .environment(\.theme, theme.withForeground(chromeForeground))
                .background { AuraGlassSurface(tint: Color(hex: tintHex), opacity: tintOpacity) }
        } else {
            content
        }
    }
}

/// The translucent layer itself, also used for the settings preview.
struct AuraGlassSurface: View {
    let tint: Color
    var opacity: Double = AuraGlass.defaultOpacity

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(tint.opacity(opacity)), in: .rect)
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(tint.opacity(opacity))
        }
    }
}

extension View {
    /// Sidebar and top toolbar only. A no-op while the setting is off.
    func auraGlassChrome() -> some View {
        modifier(GlassChromeBackground())
    }
}
