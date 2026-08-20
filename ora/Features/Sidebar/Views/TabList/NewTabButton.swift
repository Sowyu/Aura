import SwiftUI

struct NewTabButton: View {
    let addNewTab: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: addNewTab) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .frame(width: 12, height: 12)

                Text("New Tab")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .geometryGroup()
        }
        .buttonStyle(.interactive(cornerRadius: 10, tint: theme.activeTabBackground))
    }
}
