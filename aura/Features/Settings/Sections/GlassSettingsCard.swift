import SwiftUI

/// Appearance card for Liquid Glass: the toggle, the tint picker beside it, and a strip
/// that previews the chrome against a stand-in page so the tint can be judged before it
/// is applied to the window.
struct GlassSettingsCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AuraGlass.enabledKey) private var enabled = false
    @AppStorage(AuraGlass.tintKey) private var tintHex = AuraGlass.defaultTintHex
    @AppStorage(AuraGlass.opacityKey) private var tintOpacity = AuraGlass.defaultOpacity
    @AppStorage(AuraGlass.blurKey) private var blur = AuraGlass.defaultBlur

    private var tint: Color { Color(hex: tintHex) }

    /// Older builds could store 0, which reads as no chrome at all. Clamping the getter
    /// keeps the slider and the rendered chrome showing the same number.
    private var opacity: Binding<Double> {
        Binding(get: { AuraGlass.clampedOpacity(tintOpacity) }, set: { tintOpacity = $0 })
    }

    private var chromeForeground: Color {
        AuraGlass.foreground(forTintHex: tintHex, opacity: tintOpacity, colorScheme: colorScheme)
    }

    var body: some View {
        SettingsCard(
            header: "Liquid Glass (experimental)",
            description: "Makes the window chrome translucent so the desktop shows through. The page stays opaque."
        ) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Liquid Glass", isOn: $enabled)
                    // The strip previews the tint. With glass off there is no tint, and
                    // it rendered as an empty grey box that read as a broken image.
                    if enabled {
                        opacitySlider
                        blurSlider
                        preview
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if enabled {
                    AuraColorPicker(hex: $tintHex)
                }
            }
            .animation(AnimationSettings.easeOut(0.15), value: enabled)
        }
    }

    /// The floor leaves the chrome nearly clear glass, 1 makes the tint a solid fill.
    private var opacitySlider: some View {
        slider("Tint opacity", value: opacity, in: AuraGlass.minOpacity ... 1, step: 0.01)
    }

    /// Stepped, because AppKit only offers five distinct blur materials and anything
    /// between two of them would move the number without moving the chrome.
    private var blurSlider: some View {
        slider("Blur", value: $blur, in: 0 ... 1, step: 0.25)
    }

    private func slider(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Slider(value: value, in: range, step: step)
                .frame(maxWidth: 220)
            Text("\(Int(value.wrappedValue * 100))%")
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
            AuraGlassSurface(
                tint: tint,
                opacity: tintOpacity,
                blur: blur,
                blending: .withinWindow
            )
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
