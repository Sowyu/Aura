import SwiftUI

struct NewTabButton: View {
    let addNewTab: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: addNewTab) {
            HStack(spacing: 8) {
                // Same 16pt slot as a favicon, so the plus and the label sit on the
                // tab row's columns; 20pt minimum matches a row's action button.
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)

                Text("New Tab")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.secondary)
            .frame(minHeight: 20)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .geometryGroup()
        }
        .buttonStyle(InteractiveButtonStyle(
            cornerRadius: AuraRadius.row,
            hoverOpacity: colorScheme == .dark ? 0.3 : 0.1,
            pressOpacity: colorScheme == .dark ? 0.45 : 0.2,
            tint: theme.activeTabBackground
        ))
    }
}
