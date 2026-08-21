import SwiftUI

/// Readable foreground over a themed background; shared by the toolbar, glass chrome and tabs.
enum URLBarColors {
    /// Readable text colour for a tab's themed background.
    static func foreground(for tab: Tab) -> Color {
        foreground(for: tab.backgroundColor)
    }

    /// Readable text colour over an arbitrary background.
    static func foreground(for background: Color) -> Color {
        let nsColor = NSColor(background)
        guard let ciColor = CIColor(color: nsColor) else { return .black }
        let luminance = 0.299 * ciColor.red + 0.587 * ciColor.green + 0.114 * ciColor.blue
        return luminance < 0.5 ? .white : .black
    }
}
