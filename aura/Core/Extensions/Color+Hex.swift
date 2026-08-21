import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let alpha: UInt64, red: UInt64, green: UInt64, blue: UInt64
        switch hex.count {
        case 3:  // RGB (12-bit)
            (alpha, red, green, blue) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  // RGB (24-bit)
            (alpha, red, green, blue) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  // ARGB (32-bit)
            (alpha, red, green, blue) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            // Opaque gray fallback for malformed hex strings.
            (alpha, red, green, blue) = (255, 128, 128, 128)
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }

    /// Converts the Color to a hex string in `#RRGGBB` or `#RRGGBBAA` format
    func toHex(includeAlpha: Bool = false) -> String? {
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            return nil
        }

        let red = Int(rgbColor.redComponent * 255)
        let green = Int(rgbColor.greenComponent * 255)
        let blue = Int(rgbColor.blueComponent * 255)
        let alpha = Int(rgbColor.alphaComponent * 255)

        return includeAlpha
            ? String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
            : String(format: "#%02X%02X%02X", red, green, blue)
    }
}
