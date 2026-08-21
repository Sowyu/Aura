import SwiftUI

struct GradientAnimatingBorder: ViewModifier {
    let color: Color
    let trigger: Bool
    /// A one-shot decorative sweep, not interaction feedback, so it sits above the 0.15s
    /// chrome budget. Reduce motion still zeroes it, which is what the helper is for.
    private static var sweepDuration: Double { AnimationSettings.duration(0.8) }
    @State private var isAnimating = false
    @State private var showBorder = false
    // Invalidates stale hide-timeouts when the animation is re-triggered.
    @State private var animationGeneration = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if showBorder {
                    ZStack {
                        ring(lineWidth: 8, falloff: [0.8, 0.4, 0.1])
                            .blur(radius: 40)
                            .opacity(0.9)
                        ring(lineWidth: 2, falloff: [0.9, 0.6, 0.3, 0.1])
                    }
                    .onAppear(perform: startSweep)
                }
            }
            .onChange(of: trigger) { _, newTrigger in
                guard newTrigger else { return }
                isAnimating = false
                startSweep()
            }
    }

    /// One turn of the gradient. `falloff` is the trailing opacity ramp; the tail is
    /// padded with transparent stops so the sweep has a visible head and a clean gap.
    private func ring(lineWidth: CGFloat, falloff: [Double]) -> some View {
        let stops = [color] + falloff.map { color.opacity($0) }
        let colors = stops + Array(repeating: color.opacity(0), count: 8 - stops.count)
        return RoundedRectangle(cornerRadius: 16.0, style: .continuous)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: colors),
                    center: .center,
                    angle: .degrees(isAnimating ? 360 : 0)
                ),
                lineWidth: lineWidth
            )
    }

    private func startSweep() {
        showBorder = true
        animationGeneration += 1
        let generation = animationGeneration
        withAnimation(.linear(duration: Self.sweepDuration).repeatCount(1, autoreverses: false)) {
            isAnimating = true
        }
        // Hide border after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sweepDuration) {
            guard generation == animationGeneration else { return }
            withAnimation(AnimationSettings.easeOut(0.15)) {
                showBorder = false
            }
        }
    }
}
