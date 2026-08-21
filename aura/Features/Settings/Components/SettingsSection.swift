import SwiftUI

/// One set of numbers for every settings page, window and embedded tab alike.
enum SettingsMetrics {
    static let pagePadding: CGFloat = 24
    static let cardSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 16
    /// Wide enough for the longest section title. At 220 "Passwords and Autofill"
    /// truncated to "Passwords and Auto…".
    static let sidebarWidth: CGFloat = 244
    /// The space picker inside the Spaces page. Narrower than the nav sidebar: it holds
    /// one short name per row and the cards beside it need the width more.
    static let spaceListWidth: CGFloat = 180
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
