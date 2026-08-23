import SwiftUI

struct NewTabButton: View {
    let addNewTab: () -> Void

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
        .buttonStyle(.interactive(cornerRadius: AuraRadius.row, tint: theme.activeTabBackground))
    }
}
