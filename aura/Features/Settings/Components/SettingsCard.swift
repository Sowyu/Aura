import SwiftUI

/// One group of settings. Flat: a `theme.mutedBackground` fill at `AuraRadius.row` with a
/// 1pt border. No shadow, so a card reads as a grouping rather than a raised surface.
struct SettingsCard<Content: View>: View {
    var header: String?
    var description: String?
    @ViewBuilder var content: () -> Content

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if header != nil || description != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let header {
                        Text(header)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    if let description {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.mutedForeground)
                    }
                }
            }

            content()
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                .fill(theme.mutedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }
}
