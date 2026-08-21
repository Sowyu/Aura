import SwiftUI

@Observable
@MainActor
final class DialogManager {
    /// ⌘Q parks the terminate reply and puts a confirmation on screen. `AppDelegate`
    /// sets this so a second ⌘Q quits outright; it clears when the stack empties.
    @ObservationIgnored nonisolated(unsafe) static var isQuitConfirmationVisible = false

    var dialogs: [Dialog] = []

    @discardableResult
    func show(@ViewBuilder content: @escaping (String) -> some View) -> String {
        let dialog = Dialog { id in content(id) }
        withAnimation(AnimationSettings.easeOut(0.15)) {
            dialogs.append(dialog)
        }
        return dialog.id
    }

    func dismiss(id: String) {
        if let dialog = dialogs.first(where: { $0.id == id }) {
            dialog.onDismiss?()
        }
        withAnimation(AnimationSettings.easeOut(0.15)) {
            dialogs.removeAll(where: { $0.id == id })
        }
        clearQuitConfirmationIfEmpty()
    }

    func dismissTop() {
        guard let last = dialogs.last else { return }
        dismiss(id: last.id)
    }

    func dismissAll() {
        withAnimation(AnimationSettings.easeOut(0.15)) {
            dialogs.removeAll()
        }
        clearQuitConfirmationIfEmpty()
    }

    private func clearQuitConfirmationIfEmpty() {
        if dialogs.isEmpty {
            Self.isQuitConfirmationVisible = false
        }
    }

    func confirm(
        title: String,
        message: String? = nil,
        icon: OraIconType? = nil,
        iconImage: Image? = nil,
        confirmLabel: String = "Confirm",
        variant: OraButtonVariant = .default,
        onConfirm: @escaping () -> Void,
        onCancel: (() -> Void)? = nil,
        isQuitConfirmation: Bool = false
    ) {
        final class ConfirmState { var confirmed = false }
        let state = ConfirmState()

        var dialog = Dialog { id in
            ConfirmDialogView(
                title: title,
                message: message,
                icon: icon,
                iconImage: iconImage,
                confirmLabel: confirmLabel,
                confirmVariant: variant,
                onConfirm: {
                    state.confirmed = true
                    onConfirm()
                    self.dismiss(id: id)
                },
                onCancel: { self.dismiss(id: id) }
            )
        }
        dialog.onConfirm = {
            state.confirmed = true
            onConfirm()
        }
        dialog.onDismiss = {
            if !state.confirmed { onCancel?() }
        }
        dialog.isQuitConfirmation = isQuitConfirmation
        withAnimation(AnimationSettings.easeOut(0.15)) {
            dialogs.append(dialog)
        }
    }
}
