import SwiftUI

/// One set of numbers for every settings page, window and embedded tab alike.
enum SettingsMetrics {
    static let pagePadding: CGFloat = 24
    static let cardSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let sidebarWidth: CGFloat = 220
}

struct SettingsSection<Content: View>: View {
    @AppStorage("a11y.alwaysShowScrollBars") private var alwaysShowScrollBars = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                content()
            }
            .padding(SettingsMetrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(alwaysShowScrollBars ? .visible : .automatic)
    }
}
