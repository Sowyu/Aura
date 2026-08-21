import AppKit
import SwiftUI

// MARK: - Confirm Dialog

struct ConfirmDialogView: View {
    let title: String
    var message: String?
    var icon: OraIconType?
    var iconColor: Color?
    var iconImage: Image?
    var confirmLabel: String = "Confirm"
    var confirmVariant: OraButtonVariant = .default
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme

    /// Breathing room above and below the centred block.
    private static let blockPadding: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                iconView

                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(theme.foreground)

                    if let message {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundColor(theme.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Self.blockPadding)

            HStack {
                OraButton(label: "Cancel", variant: .secondary, keyboardShortcut: "esc", action: onCancel)
                Spacer()
                OraButton(label: confirmLabel, variant: confirmVariant, keyboardShortcut: "return") {
                    onConfirm()
                    onCancel()
                }
            }
        }
        // Fixed width, height from the content. Without `fixedSize` the overlay's
        // ZStack proposes the whole window height and the block stops being centred.
        .frame(width: ContainerConstants.UI.minDialogWidth)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(theme.popoverMutedBackground)
        .cornerRadius(11)
        .overlay {
            ConditionallyConcentricRectangle(cornerRadius: 11)
                .stroke(theme.border, lineWidth: 0.5)
        }
        .padding(3)
        .background(theme.popoverBackground)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    @ViewBuilder
    private var iconView: some View {
        if let iconImage {
            iconImage
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .padding(2)
                .background(Color.white)
                .cornerRadius(12)
        } else if let icon {
            OraIcons(icon: icon, size: .custom(42), color: iconColor ?? theme.mutedForeground)
        }
    }
}

// MARK: - View extension

extension View {
    func dialogs(manager: DialogManager) -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                DialogsOverlay(dialogs: manager.dialogs) { id in
                    manager.dismiss(id: id)
                }
            }
    }
}

private struct DialogsOverlay: View {
    let dialogs: [Dialog]
    let dismiss: (String) -> Void

    private static let transition: AnyTransition = .offset(y: -12).combined(with: .opacity)

    @State private var quitMonitor: Any?

    var body: some View {
        ZStack {
            if let dialog = dialogs.last {
                // Backdrop
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss(dialog.id) }
                    .transition(.opacity)

                // Dialog content — wrapped so SwiftUI sees a concrete type
                DialogContentView(content: dialog.content)
                    .id(dialog.id)
                    .transition(Self.transition)
            }
        }
        .animation(AnimationSettings.easeOut(0.15), value: dialogs.map(\.id))
        .onChange(of: dialogs.last?.isQuitConfirmation ?? false, initial: true) { _, isQuit in
            if isQuit { installQuitMonitor() } else { removeQuitMonitor() }
        }
        .onDisappear(perform: removeQuitMonitor)
    }

    /// A second ⌘Q takes the confirmation. It has to be caught here rather than in
    /// `applicationShouldTerminate`: AppKit drops `terminate:` while the first
    /// request's `terminateLater` reply is still outstanding, so the delegate is
    /// never asked again.
    private func installQuitMonitor() {
        guard quitMonitor == nil else { return }
        quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "q"
            else { return event }
            MainActor.assumeIsolated {
                guard let dialog = dialogs.last, dialog.isQuitConfirmation else { return }
                dialog.onConfirm?()
                dismiss(dialog.id)
            }
            return nil
        }
    }

    private func removeQuitMonitor() {
        guard let quitMonitor else { return }
        NSEvent.removeMonitor(quitMonitor)
        self.quitMonitor = nil
    }
}

private struct DialogContentView: View {
    let content: AnyView
    var body: some View {
        content
    }
}
