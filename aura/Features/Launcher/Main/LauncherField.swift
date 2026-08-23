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
    /// Escape. Without one, AppKit's own `cancelOperation` empties the field editor and
    /// swallows the key, so SwiftUI's `onExitCommand` never runs and nothing closes.
    var onEscape: (() -> Void)?
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
    static let height: CGFloat = 56
    static let cornerRadius: CGFloat = 8
    static let hairline: CGFloat = 0.08
    /// Leading padding, icon slot and the gap after it: where the field's text starts.
    /// Suggestion rows are inset to match, so the two columns line up.
    static let horizontalPadding: CGFloat = 24
    static let iconWidth: CGFloat = 16
    static let iconSpacing: CGFloat = 12
    static var textInset: CGFloat { horizontalPadding + iconWidth + iconSpacing }
    /// One size for the typed text and the placeholder under it.
    static let fontSize: CGFloat = 15

    var body: some View {
        HStack(alignment: .center, spacing: Self.iconSpacing) {
            if let match {
                SearchEngineCapsule(
                    text: match.text,
                    color: match.color,
                    foregroundColor: match.foregroundColor,
                    icon: match.icon
                )
            } else {
                Image(systemName: isValidURL(text) ? "globe" : "magnifyingglass")
                    .font(.system(size: Self.iconWidth, weight: .regular))
                    .foregroundStyle(theme.foreground.opacity(0.5))
                    .frame(width: Self.iconWidth, height: Self.iconWidth)
            }

            field
        }
        .padding(.horizontal, Self.horizontalPadding)
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
            font: NSFont.systemFont(ofSize: Self.fontSize, weight: .regular),
            onTab: onTab,
            onSubmit: onSubmit,
            onDelete: onDelete,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            cursorColor: match?.color ?? theme.foreground.opacity(0.8),
            textColor: theme.foreground,
            placeholder: placeholder,
            isEditing: isEditing,
            onEscape: onEscape
        )
        .textFieldStyle(PlainTextFieldStyle())
        .onChange(of: text) { _, newValue in
            onTextChange(newValue)
        }
    }
}
