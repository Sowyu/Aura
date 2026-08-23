import AppKit
import SwiftUI

/// The space pill at the top of the sidebar: which space you are in, a menu to switch,
/// and the space's own actions.
///
/// Geometry is `TabItem`'s, measured rather than eyeballed: the icon slot is 16pt at an
/// 8pt leading inset, so its left edge lands on the same column as every favicon and the
/// New Tab plus, and the trailing button's centre sits where a tab's close button does.
struct SpaceHeaderRow: View {
    /// Sidebar order, passed in so this row and the bottom switcher agree on it.
    let containers: [TabContainer]

    @Environment(\.theme) private var theme
    @Environment(\.window) private var window
    @Environment(TabManager.self) private var tabManager
    @Environment(DialogManager.self) private var dialogManager
    @Environment(ContainerManager.self) private var containerManager

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var labelAnchor: NSView?
    @State private var menuAnchor: NSView?
    @FocusState private var nameFieldFocused: Bool

    private static let height: CGFloat = 34
    private static let radius: CGFloat = AuraRadius.row
    /// `TabItem`'s icon column: 8pt of row padding, then a 16pt slot.
    private static let iconSlot: CGFloat = 16
    /// A tab's close button is 20pt wide and ends 8pt from the row edge, so its centre is
    /// 18pt in. A 24pt button with 6pt of trailing padding lands on the same centre.
    private static let trailingInset: CGFloat = 6

    var body: some View {
        if let container = tabManager.activeContainer {
            row(container)
        }
    }

    private func row(_ container: TabContainer) -> some View {
        HStack(spacing: 0) {
            label(container)
            Spacer(minLength: 4)
            menuButton(container)
        }
        .padding(.leading, 8)
        .padding(.trailing, Self.trailingInset)
        .frame(height: Self.height)
        .background(background, in: .rect(cornerRadius: Self.radius, style: .continuous))
        .contentShape(.rect(cornerRadius: Self.radius, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(AnimationSettings.easeOut(0.15), value: isHovering)
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                draftName = container.name
                nameFieldFocused = true
            }
        }
    }

    // MARK: - Label

    @ViewBuilder
    private func label(_ container: TabContainer) -> some View {
        // Leading, not centred: a glyph narrower than the slot would otherwise float a
        // pixel or two right of the favicon column it is supposed to line up with.
        HStack(spacing: 8) {
            SpaceIconView(container: container, size: 14)
                .frame(width: Self.iconSlot, height: Self.iconSlot, alignment: .leading)
            title(container)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { isRenaming = true }
        .onTapGesture {
            guard !isRenaming else { return }
            labelAnchor?.presentAuraMenu(spacesMenu(current: container))
        }
        .background(AuraMenuAnchorView { labelAnchor = $0 })
        .help("Switch Space")
        .accessibilityLabel(Text("Switch Space"))
        .accessibilityValue(Text(container.name))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func title(_ container: TabContainer) -> some View {
        if isRenaming {
            TextField("Space Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.foreground)
                .focused($nameFieldFocused)
                .onSubmit { commitRename(container) }
                .onExitCommand { isRenaming = false }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused { commitRename(container) }
                }
        } else {
            Text(container.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Always laid out, like a tab's close button, so revealing it moves nothing.
    private func menuButton(_ container: TabContainer) -> some View {
        Button {
            menuAnchor?.presentAuraMenu(actionsMenu(container))
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.foreground.opacity(0.7))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button, tint: theme.foreground))
        .background(AuraMenuAnchorView { menuAnchor = $0 })
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        .help("Space Actions")
        .accessibilityLabel(Text("Space Actions"))
    }

    /// Clear at rest like a tab row; a resting fill read as a permanent hover.
    private var background: Color {
        isHovering || isRenaming ? theme.foreground.opacity(0.06) : .clear
    }

    // MARK: - Menus

    private func spacesMenu(current: TabContainer) -> [AuraMenuItem] {
        containers.map { space in
            .item(
                SpaceMenuItems.label(for: space),
                icon: space.iconSymbol,
                state: space.id == current.id ? .checked : .none
            ) {
                withAnimation(AnimationSettings.easeOut(0.1)) {
                    tabManager.activateContainer(space)
                }
            }
        } + [
            .separator,
            .item("New Space…", icon: "plus") { showNewSpaceDialog() }
        ]
    }

    private func actionsMenu(_ container: TabContainer) -> [AuraMenuItem] {
        let index = containers.firstIndex { $0.id == container.id }
        return Array {
            AuraMenuItem.item("Rename Space…", icon: "pencil") { isRenaming = true }
            AuraMenuItem.item("Change Icon…", icon: "paintpalette") { showEditDialog(container) }
            // The only other place a space picks its container is Settings › Spaces.
            AuraMenuItem.submenu(
                "Default Container",
                icon: "square.stack.3d.up",
                items: ContainerMenuItems.choices(
                    current: container.defaultBrowsingContainer,
                    containers: containerManager.containers
                ) { containerManager.setDefault($0, for: container) }
            )
            AuraMenuItem.item("New Tab", icon: "plus", shortcut: KeyboardShortcuts.Tabs.new) {
                NotificationCenter.default.post(name: .showLauncher, object: window ?? NSApp.keyWindow)
            }
            AuraMenuItem.item("New Folder", icon: "folder.badge.plus") {
                tabManager.createFolderForRenaming(in: container)
            }
            AuraMenuItem.separator
            AuraMenuItem.item("Move Space Up", icon: "arrow.up", isDisabled: index == 0) {
                tabManager.move(container: container, by: -1, in: containers)
            }
            AuraMenuItem.item(
                "Move Space Down",
                icon: "arrow.down",
                isDisabled: index == containers.count - 1
            ) {
                tabManager.move(container: container, by: 1, in: containers)
            }
            AuraMenuItem.separator
            // Deleting the last space would leave the sidebar with nothing to page through.
            AuraMenuItem.item(
                "Delete Space…",
                icon: "trash",
                isDestructive: true,
                isDisabled: containers.count <= 1
            ) {
                confirmDelete(container)
            }
        }
    }

    // MARK: - Actions

    private func commitRename(_ container: TabContainer) {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != container.name else { return }
        tabManager.renameContainer(
            container,
            name: trimmed,
            emoji: container.emoji,
            iconSymbol: container.iconSymbol,
            iconColorHex: container.iconColorHex
        )
    }

    private func showEditDialog(_ container: TabContainer) {
        dialogManager.show { id in
            EditContainerModal(container: container, dismiss: { dialogManager.dismiss(id: id) })
                .environment(tabManager)
        }
    }

    private func showNewSpaceDialog() {
        dialogManager.show { id in
            NewContainerDialog(dismiss: { dialogManager.dismiss(id: id) })
                .environment(tabManager)
        }
    }

    private func confirmDelete(_ container: TabContainer) {
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
}
