import SwiftUI

/// The one search row, shared by the floating launcher (⌘T) and the `aura://home` page so
/// the two cannot drift apart: same height, fill, radius and hairline in both places.
struct LauncherField: View {
    @Binding var text: String
    /// Engine capsule drawn in place of the leading icon. The home page never sets one.
    var match: LauncherMatch?
    var onTab: () -> Void = {}
    let onSubmit: () -> Void
    /// `true` swallows the backspace, used to peel a matched engine back into text.
    var onDelete: () -> Bool = { false }
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    let placeholder: String
    /// The floating launcher drives focus through SwiftUI's `FocusState`; the home page
    /// pulses `isEditing` instead, because it must not hold first responder forever.
    var isFocused: FocusState<Bool>.Binding?
    var isEditing: Bool?
    var onTextChange: (String) -> Void
    /// The floating launcher draws one panel around field and suggestions, so its field
    /// has no chrome of its own; the home page shows the field alone and keeps it.
    var showsChrome = true

    @Environment(\.theme) private var theme

    /// Row height, fill and corner are the whole point of this type: change them here and
    /// both call sites move together.
    static let height: CGFloat = 52
    static let cornerRadius: CGFloat = 13
    static let hairline: CGFloat = 0.08

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let match {
                SearchEngineCapsule(
                    text: match.text,
                    color: match.color,
                    foregroundColor: match.foregroundColor,
                    icon: match.icon
                )
            } else {
                Image(systemName: isValidURL(text) ? "globe" : "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.foreground.opacity(0.5))
                    .frame(width: 18, height: 18)
            }

            field
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .background(showsChrome ? theme.launcherMainBackground : .clear)
        .clipShape(ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke((match?.color ?? theme.foreground).opacity(showsChrome ? Self.hairline : 0), lineWidth: 1)
                .padding(0.25)
        )
    }

    @ViewBuilder
    private var field: some View {
        if let isFocused {
            textField.focused(isFocused)
        } else {
            textField
        }
    }

    private var textField: some View {
        LauncherTextField(
            text: $text,
            font: NSFont.systemFont(ofSize: 16, weight: .regular),
            onTab: onTab,
            onSubmit: onSubmit,
            onDelete: onDelete,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            cursorColor: match?.color ?? theme.foreground.opacity(0.8),
            textColor: theme.foreground,
            placeholder: placeholder,
            isEditing: isEditing
        )
        .textFieldStyle(PlainTextFieldStyle())
        .onChange(of: text) { _, newValue in
            onTextChange(newValue)
        }
    }
}
