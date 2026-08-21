import AppKit
import SwiftUI

/// "Liquid Glass (experimental)": the window chrome drops its solid background for a
/// tinted translucent one that lets the desktop through. The content pane never changes,
/// so the page itself stays fully opaque and readable.
enum AuraGlass {
    static let enabledKey = "ui.glass.enabled"
    static let tintKey = "ui.glass.tintHex"
    static let opacityKey = "ui.glass.opacity"
    static let blurKey = "ui.glass.blur"
    static let defaultTintHex = "#4DABF7"

    /// How much of the tint covers the glass. Below this the chrome loses every edge
    /// against the page and the toolbar stops reading as a bar, so stored values from
    /// older builds are clamped up on read rather than migrated.
    static let minOpacity: Double = 0.05
    static let defaultOpacity: Double = 0.35

    /// How hard the chrome frosts whatever is behind the window. Quantised into five
    /// `NSVisualEffectView` materials, because that is the only blur knob AppKit exposes.
    static let defaultBlur: Double = 0.6

    static func clampedOpacity(_ value: Double) -> Double {
        min(max(value, minOpacity), 1)
    }

    /// `nil` at the bottom of the slider: no material at all, just the tint, so the
    /// desktop shows through unfrosted.
    static func material(forBlur blur: Double) -> NSVisualEffectView.Material? {
        switch (min(max(blur, 0), 1) * 4).rounded() {
        case 0: return nil
        case 1: return .titlebar
        case 2: return .sidebar
        case 3: return .hudWindow
        default: return .underWindowBackground
        }
    }

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
        let amount = clampedOpacity(opacity)
        return Color(
            red: Double(baseRGB.redComponent + (tintRGB.redComponent - baseRGB.redComponent) * amount),
            green: Double(baseRGB.greenComponent + (tintRGB.greenComponent - baseRGB.greenComponent) * amount),
            blue: Double(baseRGB.blueComponent + (tintRGB.blueComponent - baseRGB.blueComponent) * amount)
        )
    }
}

// MARK: - Window transparency

extension AuraGlass {
    /// Glass is only glass if the desktop reaches it, and an opaque window paints over
    /// every `.behindWindow` material inside it. Reverting restores AppKit's own fill.
    @MainActor
    static func applyWindowTransparency(to window: NSWindow, enabled: Bool) {
        window.isOpaque = !enabled
        window.backgroundColor = enabled ? .clear : .windowBackgroundColor
        window.titlebarAppearsTransparent = true
        // A non-opaque window derives its shadow from the rendered alpha, so the old
        // shape survives the toggle until it is thrown away explicitly.
        window.hasShadow = true
        window.invalidateShadow()
    }
}

// MARK: - Surfaces

/// The translucent layer itself, also used for the settings preview.
///
/// It clips itself rather than relying on an ancestor `clipShape`: on macOS 26 the
/// system composites `glassEffect` outside the SwiftUI clip, so the shape has to be
/// handed to the effect directly.
struct AuraGlassSurface: View {
    let tint: Color
    var opacity: Double = AuraGlass.defaultOpacity
    var blur: Double = AuraGlass.defaultBlur
    var cornerRadius: CGFloat = 0

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            if let material = AuraGlass.material(forBlur: blur) {
                // `.behindWindow`, so what frosts is the desktop rather than the page.
                BlurEffectView(material: material, blendingMode: .behindWindow, isClickThrough: true)
            }
            sheen
            shape.fill(tint.opacity(AuraGlass.clampedOpacity(opacity)))
        }
        .clipShape(shape)
    }

    /// macOS 26's glass has no blur radius of its own, only `.clear` and `.regular`, so
    /// the material above carries the slider and this adds the specular edge on top.
    @ViewBuilder
    private var sheen: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(blur < 0.5 ? .clear : .regular, in: shape)
        }
    }
}

private struct GlassChromeBackground: ViewModifier {
    let cornerRadius: CGFloat

    @AppStorage(AuraGlass.enabledKey) private var enabled = false
    @AppStorage(AuraGlass.tintKey) private var tintHex = AuraGlass.defaultTintHex
    @AppStorage(AuraGlass.opacityKey) private var tintOpacity = AuraGlass.defaultOpacity
    @AppStorage(AuraGlass.blurKey) private var blur = AuraGlass.defaultBlur
    @Environment(\.theme) private var theme

    private var chromeForeground: Color {
        AuraGlass.foreground(forTintHex: tintHex, opacity: tintOpacity, colorScheme: theme.colorScheme)
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .environment(\.theme, theme.withForeground(chromeForeground))
                .background {
                    AuraGlassSurface(
                        tint: Color(hex: tintHex),
                        opacity: tintOpacity,
                        blur: blur,
                        cornerRadius: cornerRadius
                    )
                }
        } else {
            content
        }
    }
}

/// Everything behind the chrome and around the content pane, including the corner
/// notches the pane's rounded clip cuts away. Glass has to reach here too: painting it
/// only inside the sidebar and toolbar leaves those notches in the old opaque fill, and
/// the pane stops reading as a rounded card sitting on the chrome.
private struct GlassWindowBackdrop: ViewModifier {
    @AppStorage(AuraGlass.enabledKey) private var enabled = false
    @AppStorage(AuraGlass.tintKey) private var tintHex = AuraGlass.defaultTintHex
    @AppStorage(AuraGlass.opacityKey) private var tintOpacity = AuraGlass.defaultOpacity
    @AppStorage(AuraGlass.blurKey) private var blur = AuraGlass.defaultBlur
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if enabled {
            content.background {
                AuraGlassSurface(tint: Color(hex: tintHex), opacity: tintOpacity, blur: blur)
                    .ignoresSafeArea(.all)
            }
        } else {
            content
                .background(theme.chromeBackground)
                .background(
                    BlurEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                        .ignoresSafeArea(.all)
                )
        }
    }
}

extension View {
    /// Sidebar, top toolbar and menu panels. A no-op while the setting is off.
    func auraGlassChrome(cornerRadius: CGFloat = 0) -> some View {
        modifier(GlassChromeBackground(cornerRadius: cornerRadius))
    }

    /// The one fill behind a whole browser window.
    func auraGlassWindowBackdrop() -> some View {
        modifier(GlassWindowBackdrop())
    }
}
