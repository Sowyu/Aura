import SwiftUI

struct LauncherSuggestionsView: View {
    let suggestions: [LauncherSuggestion]
    @Binding var focusedElement: UUID
    /// Row inset and icon column, so titles sit under the field's text. See
    /// `LauncherRowMetrics`.
    var leadingInset: CGFloat = 8
    var iconWidth: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(suggestions.indices, id: \.self) { index in
                LauncherSuggestionItem(
                    suggestion: suggestions[index],
                    focusedElement: $focusedElement,
                    leadingInset: leadingInset,
                    iconWidth: iconWidth
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}
