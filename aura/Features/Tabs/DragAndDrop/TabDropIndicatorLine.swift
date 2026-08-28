import SwiftUI

/// The insertion line a drag draws against a row: a hairline in the accent colour with
/// a dot at its head, so the line reads as pointing into the gap rather than
/// underlining the row it happens to touch. One view for both flows — the tab lists
/// run down the sidebar and take the horizontal line, the favourites grid runs left
/// to right and takes the vertical one.
struct TabDropIndicatorLine: View {
    /// The axis of the zone the line is drawn in, i.e. `TabDragZone.axis`, not the
    /// direction of the line itself: a `.vertical` list gets a horizontal line.
    let axis: TabDragAxis

    @Environment(\.theme) private var theme

    private static let dotSize: CGFloat = 5
    private static let lineThickness: CGFloat = 2

    var body: some View {
        switch axis {
        case .vertical:
            HStack(spacing: 0) {
                Circle()
                    .frame(width: Self.dotSize, height: Self.dotSize)
                Capsule()
                    .frame(height: Self.lineThickness)
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 2)
        case .horizontal:
            VStack(spacing: 0) {
                Circle()
                    .frame(width: Self.dotSize, height: Self.dotSize)
                Capsule()
                    .frame(width: Self.lineThickness)
            }
            .foregroundStyle(theme.accent)
            .padding(.vertical, 2)
        }
    }
}
