import SwiftUI

/// One open menu panel. Pure rendering: the pointer is tracked by `AuraMenuHost`'s event
/// monitor, so nothing here takes hits and no gesture recognisers are installed.
struct AuraMenuPanel: View {
    let level: AuraMenuController.Level
    let levelIndex: Int

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(level.items.enumerated()), id: \.element.id) { index, item in
                row(item, at: index)
            }
        }
        .padding(.vertical, AuraMenuMetrics.verticalPadding)
        .frame(width: level.size.width, height: level.size.height, alignment: .top)
        .modifier(AuraMenuSurface())
        .clipShape(.rect(cornerRadius: AuraMenuMetrics.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AuraMenuMetrics.panelRadius, style: .continuous)
                .stroke(theme.foreground.opacity(0.12), lineWidth: 1)
        }
        // The design calls for a 24pt CSS blur; SwiftUI's radius is roughly half of that.
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func row(_ item: AuraMenuItem, at index: Int) -> some View {
        switch item.kind {
        case .separator:
            Rectangle()
                .fill(theme.foreground.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        case .header:
            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.foreground.opacity(0.5))
                .lineLimit(1)
                .padding(.horizontal, AuraMenuMetrics.leadingInset)
                .frame(height: AuraMenuMetrics.headerHeight, alignment: .leading)
        case .item, .submenu:
            itemRow(item, at: index)
        }
    }

    private func itemRow(_ item: AuraMenuItem, at index: Int) -> some View {
        HStack(spacing: 8) {
            leading(item)
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundColor(theme.foreground.opacity(0.45))
            }
            if item.kind == .submenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.foreground.opacity(0.5))
            }
        }
        .foregroundColor(foreground(for: item))
        .padding(.horizontal, 5)
        .frame(height: AuraMenuMetrics.rowHeight)
        .background(fill(for: item, at: index), in: .rect(cornerRadius: AuraMenuMetrics.itemRadius))
        .padding(.horizontal, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(item.state == .none ? "" : "selected"))
        .accessibilityAction { AuraMenuController.shared.activate(level: levelIndex, row: index) }
    }

    /// The icon slot doubles as the state marker: a checked row never also needs its symbol.
    @ViewBuilder
    private func leading(_ item: AuraMenuItem) -> some View {
        switch item.state {
        case .checked:
            symbol("checkmark")
        case .radioOn:
            symbol("circle.fill", size: 7)
        case .none:
            if let icon = item.icon {
                symbol(icon)
            } else {
                Color.clear.frame(width: AuraMenuMetrics.iconSize, height: AuraMenuMetrics.iconSize)
            }
        }
    }

    private func symbol(_ name: String, size: CGFloat = 12.5) -> some View {
        Image(systemName: name)
            .font(.system(size: size))
            .frame(width: AuraMenuMetrics.iconSize, height: AuraMenuMetrics.iconSize)
    }

    private func foreground(for item: AuraMenuItem) -> Color {
        if item.isDisabled { return theme.disabledForeground }
        return item.isDestructive ? theme.destructive : theme.foreground
    }

    /// Flat fills only. A menu row that scales or bounces reads as a toy.
    private func fill(for item: AuraMenuItem, at index: Int) -> Color {
        guard item.isSelectable else { return .clear }
        let tint = item.isDestructive ? theme.destructive : theme.foreground
        if level.pressed == index { return tint.opacity(item.isDestructive ? 0.24 : 0.16) }
        if level.highlighted == index { return tint.opacity(item.isDestructive ? 0.15 : 0.1) }
        return .clear
    }
}

/// Menu background. Follows the Liquid Glass setting so a menu never looks pasted on
/// top of chrome that is translucent.
private struct AuraMenuSurface: ViewModifier {
    @AppStorage(AuraGlass.enabledKey) private var glassEnabled = false
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        if glassEnabled {
            content.auraGlassChrome()
        } else {
            content.background(.ultraThinMaterial).background(theme.popoverBackground)
        }
    }
}
