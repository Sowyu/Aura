import SwiftUI

/// Row geometry for the suggestion list. A row lines its title up with the text of the
/// field it hangs under, so the title column does not step sideways between the two.
enum LauncherRowMetrics {
    static let spacing: CGFloat = 8

    /// Pad before the icon that puts the title `textInset` from the panel's leading edge.
    static func leadingInset(textInset: CGFloat, panelPadding: CGFloat, iconWidth: CGFloat) -> CGFloat {
        max(0, textInset - panelPadding - iconWidth - spacing)
    }
}

struct LauncherSuggestionItem: View {
    let suggestion: LauncherSuggestion
    @Binding var focusedElement: UUID
    /// Pad before the icon; see `LauncherRowMetrics.leadingInset`.
    var leadingInset: CGFloat = 8
    /// Fixed icon column, so a 16pt favicon and a 14pt glyph start their titles alike.
    var iconWidth: CGFloat = 16

    @Environment(\.theme) private var theme
    @Environment(\.launcherMouseHasMoved) private var mouseHasMoved
    @Environment(AppState.self) private var appState

    private var isAIChat: Bool {
        suggestion.type == .aiChat
    }

    private var shouldShowURL: Bool {
        guard let url = suggestion.url else { return false }
        if isAIChat || suggestion.type == .suggestedQuery || suggestion.type == .openedTab { return false }
        let urlString = url.absoluteString
        if suggestion.title == urlString || urlString.hasSuffix("://\(suggestion.title)") || urlString
            .hasSuffix("://\(suggestion.title)/")
        { return false }
        return true
    }

    /// Hovering a row moves the keyboard focus onto it, so focus is the only highlight
    /// state a row needs.
    private var isFocused: Bool {
        focusedElement == suggestion.id
    }

    private var foregroundColor: Color {
        isFocused ? theme.foreground : .secondary
    }

    private var backgroundColor: Color {
        guard isFocused else { return .clear }
        return isAIChat ? theme.background : theme.foreground.opacity(0.1)
    }

    @ViewBuilder
    var icon: some View {
        if isAIChat, let suggestionIcon = suggestion.icon, !suggestionIcon.isEmpty {
            Image(suggestionIcon)
                .resizable()
                .frame(width: 14, height: 14)
        } else if suggestion.faviconURL != nil {
            FavIcon(
                isWebViewReady: true,
                favicon: suggestion.faviconURL,
                faviconLocalFile: suggestion.faviconLocalFile,
                textColor: Color(.secondaryLabelColor)
            )
        } else {
            Image(systemName: suggestion.type == .suggestedLink ? "globe" : "magnifyingglass")
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundStyle(isFocused ? theme.foreground : .secondary)
        }
    }

    @ViewBuilder
    var actionLabel: some View {
        if isAIChat {
            HStack(alignment: .center, spacing: 10) {
                Text("Ask \(suggestion.name ?? "")  ↩")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        isFocused ? theme.foreground : .secondary
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.foreground.opacity(0.07))
            .clipShape(ConditionallyConcentricRectangle(cornerRadius: 8, style: .continuous))
        } else if suggestion.type == .openedTab {
            HStack(alignment: .center, spacing: 8) {
                Text("Switch to tab ")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        isFocused ? theme.foreground : .secondary
                    )

                Image(systemName: "arrow.right")
                    .resizable()
                    .frame(width: 12, height: 12)
                    .padding(6)
                    .background(
                        ConditionallyConcentricRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                isFocused
                                    ? theme.foreground : theme.foreground.opacity(0.07)
                            )
                    )
                    .foregroundStyle(
                        isFocused ? theme.background : .secondary
                    )
            }
            .clipShape(ConditionallyConcentricRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: LauncherRowMetrics.spacing) {
            icon
                .frame(width: iconWidth)
            HStack(alignment: .center, spacing: 4) {
                Text(suggestion.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if shouldShowURL {
                    Text(" — \(suggestion.url?.absoluteString ?? "")")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(.secondaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            actionLabel
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(ConditionallyConcentricRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            suggestion.action()
            DispatchQueue.main.async {
                appState.showLauncher = false
                appState.isURLBarEditing = false
            }
        }
        .onHover { hover in
            if hover, mouseHasMoved {
                focusedElement = suggestion.id
            }
        }
    }
}
