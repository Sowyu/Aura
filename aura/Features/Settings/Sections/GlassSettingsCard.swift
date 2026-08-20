import SwiftUI

/// Appearance card for Liquid Glass: the toggle, the tint picker beside it, and a strip
/// that previews the chrome against a stand-in page so the tint can be judged before it
/// is applied to the window.
struct GlassSettingsCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AuraGlass.enabledKey) private var enabled = false
    @AppStorage(AuraGlass.tintKey) private var tintHex = AuraGlass.defaultTintHex
    @AppStorage(AuraGlass.opacityKey) private var tintOpacity = AuraGlass.defaultOpacity

    private var tint: Color { Color(hex: tintHex) }

    private var chromeForeground: Color {
        AuraGlass.foreground(forTintHex: tintHex, opacity: tintOpacity, colorScheme: colorScheme)
    }

    var body: some View {
        SettingsCard(
            header: "Liquid Glass (experimental)",
            description: "Makes the sidebar and toolbar translucent. The page itself stays opaque."
        ) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Liquid Glass", isOn: $enabled)
                    if enabled { opacitySlider }
                    preview
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if enabled {
                    AuraColorPicker(hex: $tintHex)
                }
            }
            .animation(.easeOut(duration: 0.15), value: enabled)
        }
    }

    /// 0 leaves the chrome clear glass, 1 makes the tint a solid fill.
    private var opacitySlider: some View {
        HStack(spacing: 10) {
            Text("Tint opacity")
            Slider(value: $tintOpacity, in: 0 ... 1)
                .frame(maxWidth: 220)
            Text("\(Int(tintOpacity * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var preview: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                previewRow(width: 54)
                previewRow(width: 40)
                previewRow(width: 46)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: 78, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background { previewChrome }

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .padding(6)
        }
        .frame(height: 92)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var previewChrome: some View {
        if enabled {
            AuraGlassSurface(tint: tint, opacity: tintOpacity)
        } else {
            Color(nsColor: .underPageBackgroundColor)
        }
    }

    private func previewRow(width: CGFloat) -> some View {
        Capsule()
            .fill((enabled ? chromeForeground : Color.primary).opacity(0.55))
            .frame(width: width, height: 6)
    }
}
