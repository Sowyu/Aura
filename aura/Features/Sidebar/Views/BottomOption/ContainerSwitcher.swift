import AppKit
import SwiftData
import SwiftUI

struct ContainerSwitcher: View {
    let onContainerSelected: (TabContainer) -> Void

    @Environment(\.theme) private var theme
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var dialogManager: DialogManager
    @Query var containers: [TabContainer]

    @State private var hoveredContainer: UUID?

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let totalWidth =
                CGFloat(containers.count) * ContainerConstants.UI.normalButtonWidth + CGFloat(max(
                    0,
                    containers.count - 1
                ))
                * 2
            let isCompact = totalWidth > availableWidth

            HStack(alignment: .center, spacing: isCompact ? 4 : 2) {
                ForEach(containers, id: \.id) { container in
                    containerButton(for: container, isCompact: isCompact)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(0)
        }
        .padding(0)
        .frame(height: 28)
    }

    @ViewBuilder
    private func icon(for container: TabContainer, isCollapsed: Bool, isDot: Bool, size: CGFloat) -> some View {
        if isCollapsed {
            Text(ContainerConstants.defaultEmoji)
                .font(.system(size: size))
                .foregroundColor(.primary)
        } else {
            SpaceIconView(container: container, size: size)
                .foregroundColor(isDot ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private func containerButton(for container: TabContainer, isCompact: Bool)
        -> some View
    {
        let isActive = tabManager.activeContainer?.id == container.id
        let isHovered = hoveredContainer == container.id
        // Collapsed, inactive spaces shrink to a dot until hovered.
        let isCollapsed = isCompact && !isActive && !isHovered
        let hasSymbol = container.iconSymbol?.isEmpty == false
        let isDot = !hasSymbol && container.emoji == ContainerConstants.defaultEmoji
        let buttonSize = isCompact && !isActive ?
            (isHovered ? ContainerConstants.UI.compactButtonWidth + 4 : ContainerConstants.UI.compactButtonWidth) :
            ContainerConstants.UI.normalButtonWidth
        let iconSize: CGFloat = isCollapsed ? 12 : (hasSymbol ? 14 : (isDot ? 24 : 12))

        Button(action: {
            onContainerSelected(container)
        }) {
            HStack {
                icon(for: container, isCollapsed: isCollapsed, isDot: isDot, size: iconSize)
            }
            .frame(width: buttonSize, height: buttonSize)
            .grayscale(!isActive && !isHovered ? 0.5 : 0)
            .opacity(!isActive ? 0.5 : 1)
            .background(
                !isCompact && isHovered
                    ? theme.invertedSolidWindowBackgroundColor.opacity(0.1)
                    : isActive
                    ? theme.invertedSolidWindowBackgroundColor.opacity(0.15)
                    : .clear
            )
            .cornerRadius(8)
        }
        // Hover is already driven by `hoveredContainer` (it resizes the emoji), so the
        // shared style only contributes the press feedback.
        .buttonStyle(InteractiveButtonStyle(cornerRadius: 8, hoverOpacity: 0))
        .animation(.easeOut(duration: 0.12), value: isActive || isHovered)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredContainer = isHovering ? container.id : nil
            }
        }
        .auraContextMenu { menuItems(for: container) }
    }

    private func menuItems(for container: TabContainer) -> [AuraMenuItem] {
        [
            .item("Edit Space", icon: "pencil") {
                dialogManager.show { id in
                    EditContainerModal(
                        container: container,
                        dismiss: { dialogManager.dismiss(id: id) }
                    )
                    .environmentObject(tabManager)
                }
            },
            .item("New Tab in Space", icon: "plus") {
                tabManager.activateContainer(container)
                NotificationCenter.default.post(name: .showLauncher, object: NSApp.keyWindow)
            },
            .separator,
            // Deleting the last space would leave the sidebar with nothing to page through.
            .item("Delete Space", icon: "trash", isDestructive: true, isDisabled: containers.count == 1) {
                dialogManager.confirm(
                    title: "Delete \"\(container.name)\"?",
                    message: "All tabs in this space will be permanently removed.",
                    icon: .spaceCards,
                    confirmLabel: "Delete",
                    variant: .destructive
                ) {
                    SiteSpaceRuleService.shared.removeRules(forContainer: container.id)
                    tabManager.deleteContainer(container)
                }
            }
        ]
    }
}
