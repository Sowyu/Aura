import SwiftUI

// MARK: - Size

/// The shared size scale, spelled the way the design system spells it.
enum AuraIconSize {
    // swiftlint:disable:next identifier_name
    case xs, sm, md, lg, xl
    case custom(CGFloat)

    var dimension: CGFloat {
        switch self {
        case .xs: 10
        case .sm: 12
        case .md: 16
        case .lg: 20
        case .xl: 24
        case let .custom(value): value
        }
    }
}

// MARK: - Type-erased shape wrapper

struct AnyAuraShape: Shape {
    private let _path: @Sendable (CGRect) -> Path

    init(_ shape: some Shape & Sendable) {
        _path = { shape.path(in: $0) }
    }

    func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}

// MARK: - Icon registry

enum AuraIconType {
    case star
    case circle
    case spaceCards
    case copy
    case brush1
    case custom(AnyAuraShape)

    var shape: AnyAuraShape {
        switch self {
        case .star:             AnyAuraShape(StarIcon())
        case .circle:           AnyAuraShape(Circle())
        case .spaceCards:       AnyAuraShape(SpaceCardsIcon())
        case .copy:             AnyAuraShape(CopyIcon())
        case .brush1:           AnyAuraShape(Brush1())
        case let .custom(shape): shape
        }
    }
}

// MARK: - View

struct AuraIcons: View {
    let icon: AuraIconType
    var size: AuraIconSize = .md
    var color: Color?

    @Environment(\.theme) private var theme

    var body: some View {
        icon.shape
            .fill(color ?? theme.foreground)
            .frame(width: size.dimension, height: size.dimension)
    }
}

// MARK: - Built-in icon shapes

private struct StarIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let centerX = rect.midX
        let centerY = rect.midY
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.4
        var path = Path()
        for index in 0 ..< 10 {
            let angle = (Double(index) * .pi / 5) - .pi / 2
            let radius = index.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(
                x: centerX + CGFloat(cos(angle)) * radius,
                y: centerY + CGFloat(sin(angle)) * radius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            AuraIcons(icon: .star, size: .xs)
            AuraIcons(icon: .star, size: .sm)
            AuraIcons(icon: .star, size: .md)
            AuraIcons(icon: .star, size: .lg)
            AuraIcons(icon: .star, size: .xl)
        }
        HStack(spacing: 16) {
            AuraIcons(icon: .circle, size: .xl)
            AuraIcons(icon: .star, size: .xl, color: .orange)
            AuraIcons(icon: .custom(AnyAuraShape(RoundedRectangle(cornerRadius: 4))), size: .xl)
        }
    }
    .padding(40)
    .withTheme()
}
