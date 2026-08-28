import SwiftUI

struct EmptyPinnedTabs: View {
    /// True while the drag is over the pinned section, so the target answers the
    /// pointer before anything is dropped.
    var isTargeted: Bool = false

    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin")
                .font(.system(size: 12))
                .foregroundColor(isTargeted ? theme.accent : theme.mutedForeground)

            Text("Drop here to pin a tab")
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
        .animation(AnimationSettings.easeOut(0.1), value: isTargeted)
    }
}
