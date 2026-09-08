import SwiftUI

struct SidebarPanelHeader<Actions: View>: View {
    let title: String
    @ViewBuilder let actions: () -> Actions
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(AppState.self) private var appState
    @Environment(ToolbarManager.self) private var toolbarManager
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if sidebarManager.sidebarPosition != .secondary, !toolbarManager.isRowUp {
                WindowControls(isFullscreen: appState.isFullscreen).frame(height: 30)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.foreground)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            actions()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}

struct SidebarPanelFooter: View {
    @Environment(SidebarManager.self) private var sidebarManager
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Button {
                withAnimation(AnimationSettings.easeOut(0.15)) { sidebarManager.panel = .none }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Spaces").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.foreground.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .buttonStyle(.interactive(cornerRadius: AuraRadius.button))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
    }
}
