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
    /// Empty means "follow the theme accent", the same convention `AuraAccent` uses.
    /// The chrome has no brand colour of its own, so an unset tint is the accent.
    static let defaultTintHex = AuraAccent.systemDefault

    /// How much of the tint covers the glass. Below this the chrome loses every edge
    /// against the page, so values stored by older builds are clamped up on read rather
    /// than migrated.
    static let minOpacity: Double = 0.05
    static let defaultOpacity: Double = 0.35

    /// How hard the chrome frosts whatever is behind it. Quantised into five
    /// `NSVisualEffectView` materials, because that is the only blur knob AppKit exposes.
    static let defaultBlur: Double = 0.6

    static func clampedOpacity(_ value: Double) -> Double {
        min(max(value, minOpacity), 1)
    }

    /// `nil` at the bottom of the slider: no material at all, just the tint, so what is
    /// behind shows through unfrosted.
    static func material(forBlur blur: Double) -> NSVisualEffectView.Material? {
        switch (min(max(blur, 0), 1) * 4).rounded() {
        // Ordered by measured blur strength, weakest to strongest.
        case 0: return nil
        case 1: return .hudWindow
        case 2: return .titlebar
        case 3: return .sidebar
        default: return .fullScreenUI
        }
    }

    /// The colour the glass paints with. An empty stored hex follows the theme accent,
    /// so the chrome carries the one brand colour instead of a second one.
    static func tint(forHex hex: String, theme: Theme) -> Color {
        hex.isEmpty ? theme.accent : Color(hex: hex)
    }

    /// The same resolution where only the appearance is at hand, reading the accent from
    /// the key `ThemeProvider` reads.
    static func tint(forHex hex: String, colorScheme: ColorScheme) -> Color {
        let accentHex = UserDefaults.standard.string(forKey: AuraAccent.key) ?? AuraAccent.systemDefault
        return tint(forHex: hex, theme: Theme(colorScheme: colorScheme, accentHex: accentHex))
    }

    /// Chrome text and icons flip to white or black depending on how bright the chrome
    /// ends up, which is the tint blended over whatever shows through at that opacity.
    static func foreground(forTintHex hex: String, opacity: Double, colorScheme: ColorScheme) -> Color {
        let resolved = tint(forHex: hex, colorScheme: colorScheme)
        return foreground(forTint: resolved, opacity: opacity, colorScheme: colorScheme)
    }

    static func foreground(forTint tint: Color, opacity: Double, colorScheme: ColorScheme) -> Color {
        URLBarColors.foreground(for: blended(tint: tint, opacity: opacity, colorScheme: colorScheme))
    }

    /// The tint laid over the window's own background for the current appearance.
    static func blended(tint: Color, opacity: Double, colorScheme: ColorScheme) -> Color {
        let base = NSColor(Theme(colorScheme: colorScheme).background)
        let overlay = NSColor(tint)
        guard let baseRGB = base.usingColorSpace(.sRGB), let tintRGB = overlay.usingColorSpace(.sRGB) else {
            return tint
        }
        let amount = clampedOpacity(opacity)
        return Color(
            red: Double(baseRGB.redComponent + (tintRGB.redComponent - baseRGB.redComponent) * amount),
            green: Double(baseRGB.greenComponent + (tintRGB.greenComponent - baseRGB.greenComponent) * amount),
            blue: Double(baseRGB.blueComponent + (tintRGB.blueComponent - baseRGB.blueComponent) * amount)
        )
    }

    /// Glass is only glass if the desktop reaches it, and an opaque window paints over
    /// every `.behindWindow` material inside it. Turning it off restores AppKit's fill.
    static func applyWindowTransparency(to window: NSWindow, enabled: Bool) {
        window.isOpaque = !enabled
        window.backgroundColor = enabled ? .clear : .windowBackgroundColor
        window.titlebarAppearsTransparent = true
        // A non-opaque window derives its shadow from the rendered alpha, so the shape
        // from before the toggle survives until it is thrown away explicitly.
        window.hasShadow = true
        window.invalidateShadow()
    }
}

// MARK: - Surfaces

/// The translucent layer itself, also used for the settings preview.
///
/// It clips itself rather than relying on an ancestor `clipShape`: on macOS 26 the system
/// composites `glassEffect` outside the SwiftUI clip, so the shape has to be handed to
/// the effect directly or the panel's rounded corners come back square.
struct AuraGlassSurface: View {
    let tint: Color
    var opacity: Double = AuraGlass.defaultOpacity
    var blur: Double = AuraGlass.defaultBlur
    var cornerRadius: CGFloat = 0
    /// `.behindWindow` frosts the desktop. Panels floating over a page want the page.
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            if let material = AuraGlass.material(forBlur: blur) {
                BlurEffectView(material: material, blendingMode: blending, isClickThrough: true)
            }
            sheen
            shape.fill(tint.opacity(AuraGlass.clampedOpacity(opacity)))
        }
        .clipShape(shape)
    }

    /// macOS 26's glass has no blur radius of its own, only `.clear` and `.regular`, so
    /// the material above carries the slider and this adds the specular edge over it.
    @ViewBuilder
    private var sheen: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(blur < 0.5 ? .clear : .regular, in: shape)
        }
    }
}

/// Reads the four defaults keys once for whoever needs the current glass.
private struct GlassChrome: ViewModifier {
    /// `nil` paints nothing: the window backdrop is already the surface, and a second
    /// one here would double the tint against the gutter around the content pane.
    let surfaceRadius: CGFloat?
    let blending: NSVisualEffectView.BlendingMode

    @AppStorage(AuraGlass.enabledKey) private var enabled = false
    @AppStorage(AuraGlass.tintKey) private var tintHex = AuraGlass.defaultTintHex
    @AppStorage(AuraGlass.opacityKey) private var tintOpacity = AuraGlass.defaultOpacity
    @AppStorage(AuraGlass.blurKey) private var blur = AuraGlass.defaultBlur
    @Environment(\.theme) private var theme

    private var tint: Color { AuraGlass.tint(forHex: tintHex, theme: theme) }

    private var chromeForeground: Color {
        AuraGlass.foreground(forTint: tint, opacity: tintOpacity, colorScheme: theme.colorScheme)
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .environment(\.theme, theme.withForeground(chromeForeground))
                .background {
                    if let surfaceRadius {
                        AuraGlassSurface(
                            tint: tint,
                            opacity: tintOpacity,
                            blur: blur,
                            cornerRadius: surfaceRadius,
                            blending: blending
                        )
                    }
                }
        } else {
            content
        }
    }
}

/// Everything behind the chrome and around the content pane, the corner notches its
/// rounded clip cuts away included. Glass has to reach here too: painting it only inside
/// the sidebar and the toolbar leaves those notches in the old opaque fill, and the pane
/// stops reading as a rounded card sitting on the chrome.
private struct GlassWindowBackdrop: ViewModifier {
    /// Non-zero for the revealed sidebar, which carries this same surface as a card.
    /// macOS 26 composites `glassEffect` outside an ancestor clip, so the shape has to
    /// reach the surface itself.
    let cornerRadius: CGFloat

    @AppStorage(AuraGlass.enabledKey) private var enabled = false
    @AppStorage(AuraGlass.tintKey) private var tintHex = AuraGlass.defaultTintHex
    @AppStorage(AuraGlass.opacityKey) private var tintOpacity = AuraGlass.defaultOpacity
    @AppStorage(AuraGlass.blurKey) private var blur = AuraGlass.defaultBlur
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if enabled {
            content.background {
                AuraGlassSurface(
                    tint: AuraGlass.tint(forHex: tintHex, theme: theme), opacity: tintOpacity,
                    blur: blur, cornerRadius: cornerRadius
                )
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
    /// Docked sidebar and top toolbar: chrome text colour only, because the window
    /// backdrop under them is already the glass sheet.
    func auraGlassChromeForeground() -> some View {
        modifier(GlassChrome(surfaceRadius: nil, blending: .behindWindow))
    }

    /// Panels that float over the page and carry their own sheet: menus, the floating
    /// sidebar. A no-op while the setting is off.
    func auraGlassChrome(cornerRadius: CGFloat = 0) -> some View {
        modifier(GlassChrome(surfaceRadius: cornerRadius, blending: .withinWindow))
    }

    /// The one fill behind a whole browser window, and behind the revealed sidebar so
    /// it matches the pinned one exactly.
    func auraGlassWindowBackdrop(cornerRadius: CGFloat = 0) -> some View {
        modifier(GlassWindowBackdrop(cornerRadius: cornerRadius))
    }
}
