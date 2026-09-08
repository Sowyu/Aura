import SwiftUI

/// Editing one saved page. Same card as the new-space dialog so the two read as one
/// control: title, one field per thing that can be wrong, Cancel and Save.
struct BookmarkEditDialog: View {
    let bookmark: Bookmark
    let store: BookmarkStore
    let dismiss: () -> Void

    @State private var title: String = ""
    @State private var urlString: String = ""

    private static let width: CGFloat = 380

    var body: some View {
        BookmarkDialogCard(width: Self.width, heading: "Edit Bookmark") {
            AuraInput(text: $title, placeholder: "Title", label: "Title", onSubmit: save, autofocus: true)
            AuraInput(text: $urlString, placeholder: "https://", label: "Address", onSubmit: save)
        } footer: {
            AuraButton(label: "Cancel", variant: .secondary, keyboardShortcut: "esc", action: dismiss)
            Spacer()
            AuraButton(
                label: "Save",
                isDisabled: urlString.trimmingCharacters(in: .whitespaces).isEmpty,
                keyboardShortcut: "return",
                action: save
            )
        }
        .onAppear {
            title = bookmark.title
            urlString = bookmark.urlString
        }
    }

    private func save() {
        guard !urlString.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.update(bookmark, title: title, urlString: urlString)
        dismiss()
    }
}

/// New folder, or renaming one. Nil `folder` is the new-folder case; the two differ only
/// in the heading and which store call the Save button makes.
struct BookmarkFolderDialog: View {
    let folder: BookmarkFolder?
    let store: BookmarkStore
    let dismiss: () -> Void

    @State private var name: String = ""

    private static let width: CGFloat = 340

    var body: some View {
        BookmarkDialogCard(
            width: Self.width,
            heading: folder == nil ? "New Folder" : "Rename Folder"
        ) {
            AuraInput(text: $name, placeholder: "Folder name", label: "Name", onSubmit: save, autofocus: true)
        } footer: {
            AuraButton(label: "Cancel", variant: .secondary, keyboardShortcut: "esc", action: dismiss)
            Spacer()
            AuraButton(
                label: "Save",
                isDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
                keyboardShortcut: "return",
                action: save
            )
        }
        .onAppear { name = folder?.name ?? "" }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let folder {
            store.rename(folder, to: trimmed)
        } else {
            store.createFolder(named: trimmed)
        }
        dismiss()
    }
}

/// The card both dialogs above sit in. Matches `NewContainerDialog`'s surface: an inner
/// muted panel inside a 3pt popover frame, no shadow beyond the one a floating Aura
/// surface may carry.
private struct BookmarkDialogCard<Fields: View, Footer: View>: View {
    let width: CGFloat
    let heading: String
    @ViewBuilder var fields: () -> Fields
    @ViewBuilder var footer: () -> Footer

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(theme.foreground)

            VStack(alignment: .leading, spacing: 10) {
                fields()
            }

            HStack { footer() }
        }
        .frame(width: width)
        .padding(12)
        .background(theme.popoverMutedBackground)
        .cornerRadius(AuraRadius.row)
        .overlay {
            ConditionallyConcentricRectangle(cornerRadius: AuraRadius.row)
                .stroke(theme.border, lineWidth: 0.5)
        }
        .padding(3)
        .background(theme.popoverBackground)
        .cornerRadius(AuraRadius.pane)
        .auraFloatingShadow()
    }
}
