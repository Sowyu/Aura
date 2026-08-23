import SwiftUI

/// The prompt a page's camera or microphone request raises, drawn over the top-left of
/// the page the way Safari and Chrome place theirs.
///
/// Built out of Aura's own components rather than `NSAlert`: the answer is not urgent
/// enough to take the window away from the user, and a sheet on one window would sit in
/// front of a page in another.
struct SitePermissionPromptView: View {
    let request: SitePermissionRequest

    @Environment(\.theme) private var theme
    @State private var remember = false

    private static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // A private window has nowhere to keep the answer, so it is not offered.
            if !request.isPrivate {
                Toggle("Remember this decision", isOn: $remember)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foreground)
            }
            buttons
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(theme.popoverBackground)
        .clipShape(RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AuraRadius.row, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
        .auraFloatingShadow()
        .padding(.top, 12)
        .padding(.leading, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: request.kinds.first?.symbolName ?? "lock")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(theme.foreground)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Text(request.origin)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            OraButton(label: "Don't allow", variant: .secondary, size: .sm) {
                answer(isAllowed: false)
            }
            OraButton(label: "Allow", variant: .default, size: .sm) {
                answer(isAllowed: true)
            }
        }
    }

    private var title: String {
        "\(request.host) wants to use your \(request.kinds.phrase)"
    }

    private func answer(isAllowed: Bool) {
        SitePermissionCoordinator.shared.answer(
            request,
            with: SitePermissionAnswer(isAllowed: isAllowed, remember: remember && !request.isPrivate)
        )
    }
}
