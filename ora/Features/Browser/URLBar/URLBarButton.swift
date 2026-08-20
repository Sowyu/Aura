import AppKit
import SwiftUI

struct URLBarButton: View {
    let systemName: String
    let isEnabled: Bool
    let foregroundColor: Color
    let action: () -> Void

    private var cornerRadius: CGFloat {
        if #available(macOS 26, *) {
            return 10
        } else {
            return 8
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isEnabled ? foregroundColor.opacity(0.85) : foregroundColor.opacity(0.25))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.interactive(cornerRadius: cornerRadius, tint: foregroundColor))
        .disabled(!isEnabled)
    }
}
