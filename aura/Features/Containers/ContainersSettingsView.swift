import SwiftUI

/// The container library: one row per container, with its colour, icon, name and how
/// many open tabs sit in it. Editing happens in place, so nothing here opens a sheet.
struct ContainersSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(ContainerManager.self) private var containerManager
    @Environment(DialogManager.self) private var dialogManager

    @State private var renamingID: UUID?
    @State private var editingID: UUID?
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        SettingsSection {
            SettingsCard(
                header: "Containers",
                description: "Containers keep cookies and logins separate. A tab opens in "
                    + "the container its space defaults to, or in none."
            ) {
                if containerManager.containers.isEmpty {
                    Text("No containers yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedForeground)
                } else {
                    VStack(spacing: 2) {
                        ForEach(containerManager.containers, id: \.id) { container in
                            ContainerRow(
                                container: container,
                                isRenaming: renamingID == container.id,
                                isEditing: editingID == container.id,
                                draftName: $draftName,
                                nameFieldFocused: $nameFieldFocused,
                                onBeginRename: { beginRename(container) },
                                onCommitRename: { commitRename(container) },
                                onCancelRename: { renamingID = nil },
                                onToggleEdit: {
                                    editingID = editingID == container.id ? nil : container.id
                                },
                                onDelete: { confirmDelete(container) }
                            )
                        }
                    }
                }

                Button("New Container", systemImage: "plus") { create() }
            }
        }
    }

    /// The manager picks the next palette colour itself, so a new row never comes out
    /// the same shade as the one above it.
    private func create() {
        beginRename(containerManager.create(name: "New Container"))
    }

    private func beginRename(_ container: BrowsingContainer) {
        draftName = container.name
        renamingID = container.id
        nameFieldFocused = true
    }

    private func commitRename(_ container: BrowsingContainer) {
        guard renamingID == container.id else { return }
        renamingID = nil
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != container.name else { return }
        containerManager.rename(container, to: trimmed)
    }

    /// Deleting wipes the container's cookies and logins, so it asks first.
    private func confirmDelete(_ container: BrowsingContainer) {
        dialogManager.confirm(
            title: "Delete \"\(container.name)\"?",
            message: "Its cookies and logins will be removed. Tabs in it move to no container.",
            confirmLabel: "Delete",
            variant: .destructive
        ) {
            containerManager.delete(container)
        }
    }
}

/// One container in the library. Geometry follows a sidebar row: 8pt padding, a 10pt
/// corner, and buttons that are always laid out so hovering changes opacity only.
private struct ContainerRow: View {
    let container: BrowsingContainer
    let isRenaming: Bool
    let isEditing: Bool
    @Binding var draftName: String
    @FocusState.Binding var nameFieldFocused: Bool
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onToggleEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @Environment(ContainerManager.self) private var containerManager
    @State private var isHovering = false

    private var tint: Color { Color(hex: container.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isEditing {
                palette
                iconRow
            }
        }
        .padding(8)
        .background(background, in: .rect(cornerRadius: AuraRadius.row))
        .contentShape(.rect(cornerRadius: AuraRadius.row))
        .onHover { isHovering = $0 }
        .animation(AnimationSettings.easeOut(0.12), value: isHovering)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)
            Image(systemName: container.iconSymbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
            name
            Spacer(minLength: 8)
            Text(container.tabs.count == 1 ? "1 tab" : "\(container.tabs.count) tabs")
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedForeground)
            rowButton(icon: isEditing ? "chevron.up" : "pencil", action: onToggleEdit)
                .help(isEditing ? "Done editing" : "Edit this container")
            rowButton(icon: "trash", action: onDelete)
                .help("Delete this container")
        }
    }

    @ViewBuilder
    private var name: some View {
        if isRenaming {
            TextField("Container Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.foreground)
                .focused($nameFieldFocused)
                .onSubmit(onCommitRename)
                .onExitCommand(perform: onCancelRename)
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused { onCommitRename() }
                }
        } else {
            Text(container.name)
                .font(.system(size: 13))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .contentShape(.rect)
                .onTapGesture(count: 2, perform: onBeginRename)
        }
    }

    private func rowButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.button, tint: theme.foreground))
        // Laid out either way, so revealing a button never reflows the row.
        .opacity(isHovering || isEditing ? 1 : 0)
        .allowsHitTesting(isHovering || isEditing)
    }

    private var palette: some View {
        HStack(spacing: 8) {
            ForEach(BrowsingContainer.palette, id: \.self) { hex in
                Button {
                    containerManager.recolor(container, hex: hex)
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle()
                                .stroke(theme.foreground, lineWidth: 2)
                                .opacity(hex == container.colorHex ? 1 : 0)
                                .padding(-3)
                        }
                }
                .buttonStyle(.plain)
                .help(hex)
            }
        }
        .padding(.leading, 2)
    }

    private var iconRow: some View {
        HStack(spacing: 4) {
            ForEach(BrowsingContainer.icons, id: \.self) { symbol in
                Button {
                    containerManager.reicon(container, symbol: symbol)
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(symbol == container.iconSymbol ? tint : theme.foreground)
                        .frame(width: 22, height: 22)
                        .background(
                            symbol == container.iconSymbol
                                ? theme.foreground.opacity(0.12) : .clear,
                            in: .rect(cornerRadius: AuraRadius.button)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var background: Color {
        theme.foreground.opacity(isHovering || isEditing || isRenaming ? 0.06 : 0)
    }
}
