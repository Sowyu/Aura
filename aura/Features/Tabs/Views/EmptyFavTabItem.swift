import SwiftUI

/// The favourites drop target while the grid is empty: a slim bar in the small space
/// above the space name, shown only while a dragged tab is over it. Deliberately the
/// same shape as `EmptyPinnedTabs` and not a tall promo card — it appears under a
/// pointer mid-drag, so it must not rearrange the sidebar it is being aimed at.
struct EmptyFavTabItem: View {
    /// True while the drag is over the favourites zone. The bar only mounts hovered
    /// today; the parameter keeps the resting style around for any future caller.
    var isTargeted: Bool = false

    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star")
                .font(.system(size: 12))
                .foregroundColor(isTargeted ? theme.accent : theme.mutedForeground)

            Text("Drop here to add to favorites")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isTargeted ? theme.foreground : theme.mutedForeground)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            isTargeted
                ? theme.accent.opacity(0.22)
                : theme.invertedSolidWindowBackgroundColor.opacity(0.07)
        )
        .cornerRadius(AuraRadius.row)
        .overlay(
            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                .stroke(
                    isTargeted
                        ? theme.accent.opacity(0.9)
                        : theme.invertedSolidWindowBackgroundColor.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [] : [5, 5])
                )
        )
    }
}
