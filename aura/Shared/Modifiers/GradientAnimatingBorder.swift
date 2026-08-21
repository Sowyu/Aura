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
                        // Glow effect - outer blur
                        RoundedRectangle(cornerRadius: 16.0, style: .continuous)
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [
                                        color,
                                        color.opacity(0.8),
                                        color.opacity(0.4),
                                        color.opacity(0.1),
                                        color.opacity(0.0),
                                        color.opacity(0.0),
                                        color.opacity(0.0),
                                        color.opacity(0.0)
                                    ]),
                                    center: .center,
                                    angle: .degrees(isAnimating ? 360 : 0)
                                ),
                                lineWidth: 8.0
                            )
                            .blur(radius: 40)
                            .opacity(0.9)

                        // Main border
                        RoundedRectangle(cornerRadius: 16.0, style: .continuous)
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [
                                        color,
                                        color.opacity(0.9),
                                        color.opacity(0.6),
                                        color.opacity(0.3),
                                        color.opacity(0.1),
                                        color.opacity(0.0),
                                        color.opacity(0.0),
                                        color.opacity(0.0)
                                    ]),
                                    center: .center,
                                    angle: .degrees(isAnimating ? 360 : 0)
                                ),
                                lineWidth: 2.0
                            )
                    }
                    .onAppear {
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
            }
            .onChange(of: trigger) { _, newTrigger in
                if newTrigger {
                    showBorder = true
                    isAnimating = false
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
    }
}
