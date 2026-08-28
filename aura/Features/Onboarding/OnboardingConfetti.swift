import SwiftUI

/// The one purely decorative thing in the flow: a burst of accent-coloured pieces
/// falling through the finish screen, once, on appearance. Under reduce motion every
/// duration is zero, so the pieces land and vanish in the same frame.
struct OnboardingConfetti: View {
    private struct Piece: Identifiable {
        let id: Int
        let x: CGFloat
        let delay: Double
        let color: Color
        let width: CGFloat
        let spin: Double
    }

    private static let count = 48
    private static let fall = 2.2

    @State private var pieces = Self.makePieces()
    @State private var fallen = false

    var body: some View {
        GeometryReader { geo in
            ForEach(pieces) { piece in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(piece.color)
                    .frame(width: piece.width, height: piece.width * 0.45)
                    .rotationEffect(.degrees(fallen ? piece.spin : 0))
                    .position(x: piece.x * geo.size.width, y: fallen ? geo.size.height + 24 : -24)
                    .opacity(fallen ? 0 : 1)
                    .animation(
                        .easeIn(duration: AnimationSettings.duration(Self.fall))
                            .delay(AnimationSettings.duration(piece.delay)),
                        value: fallen
                    )
            }
        }
        .allowsHitTesting(false)
        .onAppear { fallen = true }
    }

    private static func makePieces() -> [Piece] {
        let palette = AuraAccent.presets.map(\.hex).filter { !$0.isEmpty }.map { Color(hex: $0) }
        return (0 ..< count).map { index in
            Piece(
                id: index,
                x: CGFloat.random(in: 0.02 ... 0.98),
                delay: Double.random(in: 0 ... 0.6),
                color: palette[index % palette.count],
                width: CGFloat.random(in: 6 ... 11),
                spin: Double.random(in: -540 ... 540)
            )
        }
    }
}
