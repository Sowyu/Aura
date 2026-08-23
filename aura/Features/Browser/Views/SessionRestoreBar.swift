import SwiftUI

/// One line under the chrome after a crash: the tabs from the run that died are already
/// on screen, and this is the user saying whether to keep them.
///
/// It exists because "reopen the tabs I had open" is off for this user, so the launch
/// policy would otherwise have dropped those tabs before anyone saw them. The policy is
/// held back until one of the two buttons is pressed, which is why there is no way to
/// dismiss the bar without answering it.
struct SessionRestoreBar: View {
    /// Matches the bookmarks bar so the two rows read as one band of chrome.
    static let rowHeight: CGFloat = BookmarksBar.rowHeight

    @Environment(TabManager.self) private var tabManager
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.warning)
            Text("Aura quit unexpectedly. The tabs from that session are still open.")
                .font(.system(size: 11))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
            Spacer(minLength: 8)
            button("Keep previous tabs") { tabManager.keepPreviousSession() }
            button("Close them") { tabManager.discardPreviousSession() }
        }
        .padding(.horizontal, 12)
        .frame(height: BookmarksBar.itemHeight)
        .frame(height: Self.rowHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .auraGlassChromeForeground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Previous session"))
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: BookmarksBar.itemHeight)
        }
        .buttonStyle(.interactive)
        .accessibilityLabel(Text(title))
    }
}
