import SwiftUI

// MARK: - View Modifier

extension View {
    func toast(manager: ToastManager) -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: manager.position.alignment) {
                ToastsContainerView(manager: manager)
            }
    }
}

// MARK: - Enter/exit

private extension AnyTransition {
    /// Flat slide + fade. The warp this replaces scaled and rotated the panel in 3D,
    /// which is exactly the bounce the design rules rule out.
    static func slide(isTop: Bool) -> AnyTransition {
        .move(edge: isTop ? .top : .bottom).combined(with: .opacity)
    }
}

// MARK: - Toast Container (Sonner-style stacking)

private struct ToastsContainerView: View {
    let manager: ToastManager
    @State private var isExpanded: Bool = false

    private let maxVisible = 3
    private let collapsedOffset: CGFloat = 8
    private let expandedGap: CGFloat = 4
    private let estimatedToastHeight: CGFloat = 44

    private var position: ToastPosition {
        manager.position
    }

    private var isTop: Bool {
        position.isTop
    }

    /// Direction multiplier: top positions stack downward (+1), bottom positions stack upward (-1)
    private var stackDirection: CGFloat {
        isTop ? 1 : -1
    }

    var body: some View {
        let visible = Array(manager.toasts.suffix(maxVisible))

        ZStack(alignment: isTop ? .top : .bottom) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, toast in
                let depth = visible.count - 1 - index // 0 = newest (front)

                ToastItemView(toast: toast) {
                    manager.dismiss(id: toast.id)
                }
                .offset(y: dragOffset(for: toast))
                // Depth reads from the offset alone. Scaling the stack on hover was the
                // one place chrome grew under the pointer.
                .offset(
                    y: isExpanded
                        ? CGFloat(depth) * (estimatedToastHeight + expandedGap) * stackDirection
                        : CGFloat(depth) * collapsedOffset * stackDirection
                )
                .opacity(depth >= maxVisible ? 0 : 1)
                .zIndex(Double(index))
                .gesture(swipeToDismiss(toast: toast))
                .transition(.slide(isTop: isTop))
            }
        }
        .padding(isTop ? .top : .bottom, 20)
        .padding(.horizontal, 20)
        .onHover { hovering in
            withAnimation(AnimationSettings.easeOut(0.15)) {
                isExpanded = hovering
            }
            if hovering {
                manager.pauseTimers()
            } else {
                manager.resumeTimers()
            }
        }
        .animation(AnimationSettings.easeOut(0.15), value: manager.toasts.map(\.id))
    }

    private func dragOffset(for toast: Toast) -> CGFloat {
        if isTop {
            return min(toast.dragOffsetY, 0)
        } else {
            return max(toast.dragOffsetY, 0)
        }
    }

    private func swipeToDismiss(toast: Toast) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if let idx = manager.toasts.firstIndex(where: { $0.id == toast.id }) {
                    manager.toasts[idx].dragOffsetY = value.translation.height
                }
            }
            .onEnded { value in
                if let idx = manager.toasts.firstIndex(where: { $0.id == toast.id }) {
                    let dismissed = isTop
                        ? value.translation.height < -60
                        : value.translation.height > 60

                    if dismissed {
                        let flyOut: CGFloat = isTop ? -300 : 300
                        withAnimation(AnimationSettings.easeOut(0.15)) {
                            manager.toasts[idx].dragOffsetY = flyOut
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            manager.dismiss(id: toast.id)
                        }
                    } else {
                        withAnimation(AnimationSettings.easeOut(0.15)) {
                            manager.toasts[idx].dragOffsetY = 0
                        }
                    }
                }
            }
    }
}

// MARK: - Individual Toast

struct ToastItemView: View {
    let toast: Toast
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if let icon = toast.resolvedIcon {
                toastIconView(icon)
            }

            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.foreground)
                .lineLimit(2)

            Spacer(minLength: 10)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.foreground.opacity(0.4))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 356)
        .background(theme.popoverBackground)
        .clipShape(ConditionallyConcentricRectangle(cornerRadius: AuraRadius.pane))
        .overlay(
            ConditionallyConcentricRectangle(cornerRadius: AuraRadius.pane)
                .stroke(theme.border, lineWidth: 1)
        )
        .auraFloatingShadow()
    }

    @ViewBuilder
    private func toastIconView(_ icon: ToastIcon) -> some View {
        switch icon {
        case let .system(name):
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(toast.type.iconColor(theme: theme))
        case let .asset(name):
            Image(name)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        case let .view(content):
            content
                .frame(width: 16, height: 16)
        }
    }
}
