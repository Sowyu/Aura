import SwiftUI

/// Shown when a download would land on a name that is already taken.
///
/// The auto-save path used to rename silently, which is how a Downloads folder ends up
/// with six copies of the same installer and no way to tell which one is current. Same
/// three answers the save panel gives, in the same chrome as `ConfirmDialogView` so the
/// dialog stack stays one visual language.
struct DownloadCollisionDialog: View {
    let fileName: String
    let folderName: String
    let choose: (DownloadCollisionChoice) -> Void

    @Environment(\.theme) private var theme

    /// Breathing room above and below the centred block, matching `ConfirmDialogView`.
    private static let blockPadding: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 34))
                    .foregroundColor(theme.mutedForeground)
                    .frame(width: 42, height: 42)

                VStack(spacing: 6) {
                    Text("\u{201C}\(fileName)\u{201D} already exists")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(theme.foreground)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Text("A file with that name is already in \(folderName).")
                        .font(.system(size: 13))
                        .foregroundColor(theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Self.blockPadding)

            HStack(spacing: 8) {
                OraButton(label: "Cancel", variant: .secondary, keyboardShortcut: "esc") {
                    choose(.cancel)
                }
                Spacer()
                OraButton(label: "Replace", variant: .destructive) {
                    choose(.replace)
                }
                // The safe answer takes return: it is the one that cannot lose a file.
                OraButton(label: "Keep both", variant: .default, keyboardShortcut: "return") {
                    choose(.keepBoth)
                }
            }
        }
        // Fixed width, height from the content. Without `fixedSize` the overlay's
        // ZStack proposes the whole window height and the block stops being centred.
        .frame(width: ContainerConstants.UI.minDialogWidth)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(theme.popoverMutedBackground)
        .cornerRadius(AuraRadius.row)
        .overlay {
            ConditionallyConcentricRectangle(cornerRadius: AuraRadius.row)
                .stroke(theme.border, lineWidth: 1)
        }
        // 3pt inset inside the 13pt outer edge keeps the two corners concentric.
        .padding(3)
        .background(theme.popoverBackground)
        .cornerRadius(AuraRadius.pane)
        .auraFloatingShadow()
    }
}
