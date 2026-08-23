import AppKit
import SwiftUI

struct PasswordAutofillOverlayView: View {
    let overlay: PasswordAutofillOverlayState
    let tab: Tab

    private let overlayWidth: CGFloat = 320
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .frame(width: overlayWidth)
            .background(theme.popoverBackground)
            .clipShape(RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
            .auraFloatingShadow()
            .offset(
                x: max(12, overlay.focus.rect.cgRect.minX),
                y: overlay.focus.rect.cgRect.maxY + 10
            )
            .allowsHitTesting(true)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            if overlay.suggestions.isEmpty {
                Text("No autofill suggestions available.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(overlay.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    PasswordSuggestionButton(
                        host: suggestion.host,
                        isSelected: overlay.selectedSuggestionIndex == index,
                        accessorySymbolName: suggestion.accessorySymbolName
                    ) {
                        activate(suggestion)
                    } onHoverChanged: { isHovering in
                        if isHovering {
                            tab.passwordCoordinator?.updateSelection(to: index, for: overlay)
                        }
                    } content: {
                        suggestionContent(for: suggestion)
                    }
                }
            }
            VStack {}.frame(height: 2)
            Divider()

            Button {
                tab.passwordCoordinator?.openPasswordsManager()
            } label: {
                Text("Manage Passwords")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.interactive(cornerRadius: AuraRadius.row))
        }
        .padding(8)
    }

    @ViewBuilder
    private func suggestionContent(for suggestion: PasswordAutofillSuggestion) -> some View {
        switch suggestion {
        case let .generatedPassword(_, password):
            VStack(alignment: .leading, spacing: 3) {
                Text("Use Strong Password")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                Text(password)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.mutedForeground)
                    .lineLimit(1)
            }
        case let .savedCredential(entry):
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayUsername)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                Text(entry.host)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
            }
        case let .email(suggestion):
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.email)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                Text("Use email from \(suggestion.host)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
            }
        }
    }

    private func activate(_ suggestion: PasswordAutofillSuggestion) {
        switch suggestion {
        case .generatedPassword:
            tab.passwordCoordinator?.fillGeneratedPassword(for: overlay)
        case let .savedCredential(entry):
            tab.passwordCoordinator?.autofill(entry, for: overlay)
        case let .email(emailSuggestion):
            tab.passwordCoordinator?.fillEmailSuggestion(emailSuggestion, for: overlay)
        }
    }
}

private extension PasswordAutofillSuggestion {
    var accessorySymbolName: String {
        switch self {
        case .generatedPassword:
            return "key.horizontal.fill"
        case .savedCredential:
            return "touchid"
        case .email:
            return "at"
        }
    }
}

struct PasswordAutofillTriggerView: View {
    let overlay: PasswordAutofillOverlayState
    let tab: Tab

    private let buttonSize: CGFloat = 24
    private let fieldInset: CGFloat = 9
    private let cornerRadius: CGFloat = 6

    @State private var isHovering = false

    var body: some View {
        GeometryReader { proxy in
            Button {
                tab.passwordCoordinator?.presentTriggerOverlay()
            } label: {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: "#4A4A4A"))
                    .frame(width: buttonSize, height: buttonSize)
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                Color(hex: "#EFEFEF")
                                    .opacity(isHovering ? 1 : 0.7)
                            )
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.8)
                            .fill(Color.white.opacity(isHovering ? 0.08 : 0))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .buttonStyle(InteractiveButtonStyle(cornerRadius: cornerRadius, hoverOpacity: 0))
            .onHover { isHovering = $0 }
            .offset(
                x: triggerX(in: proxy.size),
                y: triggerY(in: proxy.size)
            )
        }
    }

    private func triggerX(in size: CGSize) -> CGFloat {
        let rect = overlay.focus.rect.cgRect
        let preferred = rect.maxX - buttonSize - fieldInset
        return min(max(8, preferred), max(8, size.width - buttonSize - 8))
    }

    private func triggerY(in size: CGSize) -> CGFloat {
        let rect = overlay.focus.rect.cgRect
        let preferred = rect.midY - (buttonSize / 2)
        return min(max(8, preferred), max(8, size.height - buttonSize - 8))
    }
}

private struct PasswordSuggestionButton<Content: View>: View {
    let host: String
    let isSelected: Bool
    let accessorySymbolName: String
    let action: () -> Void
    let onHoverChanged: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SiteFaviconView(host: host, size: 18)
                content()
                Spacer(minLength: 0)
                // Laid out either way, only the opacity moves, so the row never reflows.
                Image(systemName: accessorySymbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.mutedForeground)
                    .opacity(isSelected ? 1 : 0.3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // Only the keyboard selection paints a fill here; hover is the button style's job.
            .background(
                RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                    .fill(isSelected ? theme.mutedBackground : .clear)
            )
        }
        .buttonStyle(.interactive(cornerRadius: AuraRadius.row))
        .onHover { onHoverChanged($0) }
        .animation(AnimationSettings.easeOut(0.1), value: isSelected)
    }
}

struct SiteFaviconView: View {
    let host: String
    var size: CGFloat = 24
    var cornerRadius: CGFloat = AuraRadius.button

    @Environment(\.theme) private var theme
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .overlay {
                        Image(systemName: "globe")
                            .resizable()
                            .scaledToFit()
                            .padding(2)
                            .frame(width: size, height: size)
                            .foregroundStyle(theme.mutedForeground)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear(perform: loadFavicon)
        .onChange(of: host) {
            loadFavicon()
        }
    }

    private func loadFavicon() {
        let normalizedHost = PasswordManagerService.normalizeHost(host)
        guard !normalizedHost.isEmpty else {
            image = nil
            return
        }

        FaviconService.shared.fetchFaviconSync(for: "https://\(normalizedHost)") { favicon in
            DispatchQueue.main.async {
                self.image = favicon
            }
        }
    }
}
