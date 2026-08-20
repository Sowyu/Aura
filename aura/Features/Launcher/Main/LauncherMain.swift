import SwiftUI

struct LauncherMain: View {
    @Binding var text: String
    @Binding var match: LauncherMatch?
    var isFocused: FocusState<Bool>.Binding
    let onTabPress: () -> Void
    @ObservedObject var viewModel: LauncherViewModel

    @Environment(\.theme) private var theme

    /// Gap between the panel edge and the field, and between the field and the list.
    private static let panelPadding: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LauncherField(
                text: $text,
                match: match,
                onTab: onTabPress,
                onSubmit: { viewModel.executeCommand() },
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
                placeholder: getPlaceholder(match: match),
                isFocused: isFocused,
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
                    text: $text,
                    suggestions: $viewModel.suggestions,
                    focusedElement: $viewModel.focusedElement
                )
                .padding(Self.panelPadding)
            }
        }
        .background(theme.launcherMainBackground)
        .background(BlurEffectView(material: .popover, blendingMode: .withinWindow))
        .clipShape(ConditionallyConcentricRectangle(cornerRadius: LauncherField.cornerRadius, style: .continuous))
        .overlay(
            ConditionallyConcentricRectangle(cornerRadius: LauncherField.cornerRadius, style: .continuous)
                .stroke((match?.color ?? theme.foreground).opacity(0.12), lineWidth: 1)
                .padding(0.25)
        )
        .shadow(color: .black.opacity(0.35), radius: 32, x: 0, y: 12)
    }

    private func getPlaceholder(match: LauncherMatch?) -> String {
        guard let match else {
            return "Search the web or enter url..."
        }

        if let engine = viewModel.searchEngineService.getSearchEngine(byName: match.text) {
            let prefix = engine.isAIChat ? "Ask" : "Search on"
            return "\(prefix) \(engine.name)"
        }

        return "Search on \(match.text)"
    }
}
