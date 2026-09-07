import SwiftUI

struct LauncherMain: View {
    @Binding var text: String
    @Binding var match: LauncherMatch?
    var isFocused: FocusState<Bool>.Binding
    let onTabPress: () -> Void
    let onEscape: () -> Void
    @ObservedObject var viewModel: LauncherViewModel

    @Environment(\.theme) private var theme

    /// Gap between the panel edge and the field, and between the field and the list.
    private static let panelPadding: CGFloat = 6

    /// One flat surface: solid fill, one hairline border, 8 pt corner. No blur, and no
    /// second outline around the field inside it.
    private static let cornerRadius: CGFloat = LauncherField.cornerRadius

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LauncherField(
                text: $text,
                match: match,
                onTab: onTabPress,
                // With an engine capsule showing there is no visible list, so Enter runs
                // the search rather than whichever row focus was left on.
                onSubmit: { match == nil ? viewModel.executeCommand() : viewModel.submitTypedText() },
                onDelete: {
                    if text.isEmpty, let currentMatch = match {
                        text = currentMatch.originalAlias
                        match = nil
                        return true
                    }
                    return false
                },
                onMoveUp: { viewModel.moveFocusedElement(.up) },
                onMoveDown: { viewModel.moveFocusedElement(.down) },
                onEscape: onEscape,
                placeholder: getPlaceholder(match: match),
                isFocused: isFocused,
                // Asks AppKit for first responder directly, the way the address bar and
                // the home page do. SwiftUI's focus bridge onto the field, `isFocused`
                // above, did not reliably land the caret on ⌘T. Constant while mounted:
                // the launcher is modal and nothing else in it takes focus.
                isEditing: true,
                onTextChange: { newValue in
                    viewModel.currentText = newValue
                    viewModel.searchHandler(newValue)
                },
                showsChrome: false
            )
            .animation(nil, value: match?.color)

            if match == nil, !viewModel.suggestions.isEmpty {
                Divider().overlay(theme.foreground.opacity(0.08))
                LauncherSuggestionsView(
                    suggestions: $viewModel.suggestions,
                    focusedElement: $viewModel.focusedElement,
                    leadingInset: LauncherRowMetrics.leadingInset(
                        textInset: LauncherField.textInset,
                        panelPadding: Self.panelPadding,
                        iconWidth: LauncherField.iconWidth
                    ),
                    iconWidth: LauncherField.iconWidth
                )
                .padding(Self.panelPadding)
            }
        }
        .background(theme.popoverBackground)
        .clipShape(ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            ConditionallyConcentricRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
                .padding(0.25)
        )
        .auraFloatingShadow()
    }

    private func getPlaceholder(match: LauncherMatch?) -> String {
        guard let match else {
            let engine = viewModel.searchEngineService.getDefaultSearchEngine(
                for: viewModel.tabManager?.activeContainer?.id
            )
            return "Search with \(engine?.name ?? "Google") or enter address"
        }

        if let engine = viewModel.searchEngineService.getSearchEngine(byName: match.text) {
            let prefix = engine.isAIChat ? "Ask" : "Search on"
            return "\(prefix) \(engine.name)"
        }

        return "Search on \(match.text)"
    }
}
