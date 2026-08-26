import AppKit
import SwiftUI

/// In-app colour picker. Deliberately not `ColorPicker`/`NSColorPanel`: those open a
/// separate system window that floats over the browser and ignores Aura's styling.
///
/// Hex is written back as `#RRGGBB`, or `#AARRGGBB` once the intensity slider leaves
/// full opacity, which is the byte order `Color(hex:)` reads.
struct AuraColorPicker: View {
    @Binding var hex: String

    private static let panelWidth: CGFloat = 200
    private static let squareHeight: CGFloat = 120
    private static let barHeight: CGFloat = 12
    private static let knobSize: CGFloat = 12

    @Environment(\.theme) private var theme

    @State private var hue: Double = 0.58
    @State private var saturation: Double = 0.7
    @State private var value: Double = 0.97
    @State private var intensity: Double = 1
    @State private var hexField = ""

    private var current: Color {
        Color(hue: hue, saturation: saturation, brightness: value, opacity: intensity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            saturationSquare
            hueBar
            intensityBar
            presetRow
            hexRow
        }
        .frame(width: Self.panelWidth)
        .onAppear(perform: load)
        .onChange(of: hex) { _, newValue in
            guard newValue.uppercased() != hexField else { return }
            load()
        }
    }

    // MARK: - Saturation / brightness

    private var saturationSquare: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [.white, Color(hue: hue, saturation: 1, brightness: 1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)

                knob(filledWith: Color(hue: hue, saturation: saturation, brightness: value))
                    .offset(
                        x: saturation * geo.size.width - Self.knobSize / 2,
                        y: (1 - value) * geo.size.height - Self.knobSize / 2
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    saturation = clamped(drag.location.x / geo.size.width)
                    value = 1 - clamped(drag.location.y / geo.size.height)
                    commit()
                }
            )
        }
        .frame(height: Self.squareHeight)
    }

    // MARK: - Bars

    private var hueBar: some View {
        bar(
            fill: LinearGradient(
                colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6.0)
                    .map { Color(hue: $0, saturation: 1, brightness: 1) },
                startPoint: .leading,
                endPoint: .trailing
            ),
            knobColor: Color(hue: hue, saturation: 1, brightness: 1),
            fraction: hue
        ) { fraction in
            hue = fraction
            commit()
        }
    }

    private var intensityBar: some View {
        bar(
            fill: LinearGradient(
                colors: [
                    Color(hue: hue, saturation: saturation, brightness: value, opacity: 0),
                    Color(hue: hue, saturation: saturation, brightness: value)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            knobColor: current,
            fraction: intensity
        ) { fraction in
            intensity = fraction
            commit()
        }
    }

    private func bar<Fill: ShapeStyle>(
        fill: Fill,
        knobColor: Color,
        fraction: Double,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(fill)
                knob(filledWith: knobColor)
                    .offset(x: fraction * geo.size.width - Self.knobSize / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    onChange(clamped(drag.location.x / geo.size.width))
                }
            )
        }
        .frame(height: Self.barHeight)
    }

    private func knob(filledWith color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: Self.knobSize, height: Self.knobSize)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .auraFloatingShadow()
    }

    // MARK: - Presets and hex

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(SpaceIconCatalog.palette, id: \.self) { preset in
                Button {
                    hex = preset
                    load()
                } label: {
                    Circle()
                        .fill(Color(hex: preset))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(
                                    isSelected(preset) ? theme.foreground.opacity(0.8) : theme.border,
                                    lineWidth: 1.5
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var hexRow: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
                .fill(preview)
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: AuraRadius.button, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )
            TextField("#RRGGBB", text: $hexField)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(applyHexField)
        }
    }

    // MARK: - Conversion

    private func isSelected(_ preset: String) -> Bool {
        preset.caseInsensitiveCompare(hexField) == .orderedSame
    }

    /// The typed hex shows in the swatch as it is typed; committing it still waits for
    /// Return, so a half-typed value never reaches the binding.
    private var preview: Color {
        Self.normalizedHex(hexField).map { Color(hex: $0) } ?? current
    }

    /// `#RGB`, `#RRGGBB` or `#AARRGGBB`, the forms `Color(hex:)` reads. Anything else is
    /// rejected: `Scanner` stops at the first bad character, so "#GG00ZZ" used to scan as
    /// zero and paint the swatch black without a word.
    static func normalizedHex(_ input: String) -> String? {
        let digits = input.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "#" }
        guard [3, 6, 8].contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else {
            return nil
        }
        return "#" + digits.uppercased()
    }

    private func clamped(_ input: Double) -> Double {
        min(max(input, 0), 1)
    }

    private func load() {
        // An empty or malformed stored hex means "no colour of its own yet", which is
        // the theme accent rather than the grey `Color(hex:)` falls back to.
        let base = Self.normalizedHex(hex).map { Color(hex: $0) } ?? theme.accent
        guard let resolved = NSColor(base).usingColorSpace(.sRGB) else { return }
        var hueOut: CGFloat = 0
        var satOut: CGFloat = 0
        var valueOut: CGFloat = 0
        var alphaOut: CGFloat = 0
        resolved.getHue(&hueOut, saturation: &satOut, brightness: &valueOut, alpha: &alphaOut)
        hue = Double(hueOut)
        saturation = Double(satOut)
        value = Double(valueOut)
        intensity = Double(alphaOut)
        hexField = hex.uppercased()
    }

    private func applyHexField() {
        guard let normalized = Self.normalizedHex(hexField) else {
            hexField = hex.uppercased()
            return
        }
        hex = normalized
        load()
    }

    private func commit() {
        guard let srgb = NSColor(current).usingColorSpace(.sRGB) else { return }
        let red = Int((srgb.redComponent * 255).rounded())
        let green = Int((srgb.greenComponent * 255).rounded())
        let blue = Int((srgb.blueComponent * 255).rounded())
        let alpha = Int((srgb.alphaComponent * 255).rounded())
        hex = alpha >= 255
            ? String(format: "#%02X%02X%02X", red, green, blue)
            : String(format: "#%02X%02X%02X%02X", alpha, red, green, blue)
        hexField = hex
    }
}
