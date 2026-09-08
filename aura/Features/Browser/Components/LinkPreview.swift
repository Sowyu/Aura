import SwiftUI

struct LinkPreview: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack {
            Spacer()
            HStack {
                ZStack {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                        .fill(theme.popoverBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                                .stroke(theme.border, lineWidth: 1)
                        )
                )

                Spacer()
            }
            .padding(.bottom, 8)
            .padding(.leading, 8)
        }
        .transition(.opacity)
        .animation(AnimationSettings.easeOut(0.1), value: text)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .zIndex(900)
    }
}
