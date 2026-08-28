import SwiftUI

/// The accent presets as a row of swatches. One view for Look and Feel and for the
/// welcome flow's style screen, so the two can never offer different colours.
struct AccentPresetRow: View {
    @Environment(\.theme) private var theme
    @AppStorage(AuraAccent.key) private var accentHex = AuraAccent.systemDefault

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AuraAccent.presets, id: \.name) { preset in
                swatch(name: preset.name, hex: preset.hex)
            }
        }
    }

    private func swatch(name: String, hex: String) -> some View {
        let isSelected = accentHex == hex
        let swatch = hex.isEmpty ? Theme(colorScheme: .light).accent : Color(hex: hex)
        return Button {
            accentHex = hex
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(swatch)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Circle().stroke(theme.foreground.opacity(isSelected ? 0.8 : 0.15), lineWidth: 2)
                    }
                Text(name)
                    .font(.system(size: 11))
                    .fontWeight(isSelected ? .semibold : .regular)
            }
        }
        .buttonStyle(.plain)
        .help(name)
    }
}
