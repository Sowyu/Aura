import AppKit
import SwiftUI

/// The one accent colour the chrome tints itself with. Stored as a hex string so it
/// rides in `@AppStorage` next to the glass tint.
enum AuraAccent {
    static let key = "ui.theme.accent"
    /// Empty means "use the built-in orange", which still flips with the appearance.
    static let systemDefault = ""

    static let presets: [(name: String, hex: String)] = [
        ("Aura", systemDefault),
        ("Blue", "#4DABF7"),
        ("Purple", "#9775FA"),
        ("Pink", "#F06595"),
        ("Green", "#51CF66"),
        ("Yellow", "#FCC419"),
        ("Graphite", "#868E96")
    ]
}

/// The radius scale. Every surface picks one of these; a literal radius anywhere else
/// is a bug. Buttons and chips 6, rows/fields/cards/menus/overlays 10, panes 13.
enum AuraRadius {
    static let button: CGFloat = 6
    static let row: CGFloat = 10
    static let pane: CGFloat = 13
}

/// Flat chrome floats on a 1pt `theme.border` line, and at most this much shadow.
/// Anything larger reads as a different elevation model next to the content pane.
enum AuraShadow {
    static let radius: CGFloat = 6
    static let y: CGFloat = 2
    static let opacity: Double = 0.12
}

extension View {
    /// The one shadow a floating Aura surface may carry.
    func auraFloatingShadow() -> some View {
        shadow(color: .black.opacity(AuraShadow.opacity), radius: AuraShadow.radius, y: AuraShadow.y)
    }
}

struct Theme: Equatable {
    let colorScheme: ColorScheme
    /// Set only on the glass chrome, where readable text follows the tint's luminance
    /// rather than the system appearance.
    var forcedForeground: Color?
    /// User-chosen accent. Empty falls back to the built-in orange.
    var accentHex: String = AuraAccent.systemDefault

    var primary: Color {
        Color(hex: "#f3e5d6")
    }

    var primaryDark: Color {
        Color(hex: "#141414")
    }

    var accent: Color {
        guard accentHex.isEmpty else { return Color(hex: accentHex) }
        return colorScheme == .dark ? Color(hex: "#FF9B51") : Color(hex: "#F16D34")
    }

    var background: Color {
        colorScheme == .dark ? Color(hex: "#0F0E0E") : .white
    }

    var foreground: Color {
        forcedForeground ?? (colorScheme == .dark ? .white : .black)
    }

    func withForeground(_ color: Color) -> Theme {
        var copy = self
        copy.forcedForeground = color
        return copy
    }

    /// The one fill behind every piece of window chrome: the pinned toolbar row, the
    /// sidebar, and both of their floating counterparts. Translucent, so the window
    /// blur underneath still shows through.
    var chromeBackground: Color {
        colorScheme == .dark ? self.primaryDark.opacity(0.3) : self.primary.opacity(0.3)
    }

    var solidWindowBackgroundColor: Color {
        colorScheme == .dark ? self.primaryDark : self.primary
    }

    var invertedSolidWindowBackgroundColor: Color {
        colorScheme == .dark ? self.primary : self.primaryDark
    }

    var activeTabBackground: Color {
        colorScheme == .dark ? .white.opacity(0.15) : self.primaryDark.opacity(0.8)
    }

    var mutedBackground: Color {
        colorScheme == .dark ? .white.opacity(0.17) : self.primaryDark.opacity(0.1)
    }

    var popoverBackground: Color {
        colorScheme == .dark ? Color(hex: "#242424") : .white
    }

    var popoverMutedBackground: Color {
        colorScheme == .dark ? Color(hex: "#1d1d1d") : self.primaryDark.opacity(0.1)
    }

    var mutedForeground: Color {
        .secondary
    }

    var disabledBackground: Color {
        colorScheme == .dark ? .black.opacity(0.3) : .white.opacity(0.3)
    }

    var disabledForeground: Color {
        colorScheme == .dark ? .white.opacity(0.3) : Color(.disabledControlTextColor)
    }

    var launcherMainBackground: Color {
        colorScheme == .dark ? self.popoverBackground.opacity(0.75) : .white.opacity(0.8)
    }

    var placeholder: Color {
        Color(.placeholderTextColor)
    }

    var border: Color {
        Color(.separatorColor)
    }

    var destructive: Color {
        Color(hex: "#FF6969")
    }

    var success: Color {
        Color(hex: "#93DA97")
    }

    var warning: Color {
        Color(hex: "#FFBF78")
    }

    var info: Color {
        Color(hex: "#799EFF")
    }

    /// Search engine colors
    var grok: Color {
        colorScheme == .dark ? .white : .black
    }

    var claude: Color {
        Color(hex: "#d97757")
    }

    var openai: Color {
        colorScheme == .dark ? .white : .black
    }

    var t3chat: Color {
        Color(hex: "#960971")
    }

    var perplexity: Color {
        Color(hex: "#20808D")
    }

    var reddit: Color {
        Color(hex: "#FF4500")
    }

    // swiftlint:disable:next identifier_name
    var x: Color {
        colorScheme == .dark ? .white : .black
    }

    var google: Color {
        .blue
    }

    var youtube: Color {
        Color(hex: "#FC0D1B")
    }

    var github: Color {
        colorScheme == .dark ? .white : Color(hex: "#181717")
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(colorScheme: .light)  // fallback
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct ThemeProvider: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AuraAccent.key) private var accentHex = AuraAccent.systemDefault

    func body(content: Content) -> some View {
        content.environment(\.theme, Theme(colorScheme: colorScheme, accentHex: accentHex))
    }
}
