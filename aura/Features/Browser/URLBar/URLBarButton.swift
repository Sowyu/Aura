import AppKit
import SwiftUI

/// The single icon button used by every chrome row: top toolbar, floating URL
/// bar, sidebar header. Keeping one type is what makes them look identical.
struct URLBarButton: View {
    static let cornerRadius: CGFloat = 6
    static let iconSize: CGFloat = 14
    static let disabledOpacity: Double = 0.35

    let systemName: String
    let isEnabled: Bool
    let foregroundColor: Color
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundColor(foregroundColor.opacity(isEnabled ? 0.85 : Self.disabledOpacity))
                .frame(width: size, height: size)
        }
        .buttonStyle(.interactive(cornerRadius: Self.cornerRadius, tint: foregroundColor))
        .disabled(!isEnabled)
    }
}
