import Foundation

/// Constants related to container functionality
enum ContainerConstants {
    /// Default emoji used when no emoji is selected for a container
    static let defaultEmoji = "•"

    /// Glyph a new space starts with. A `SpaceIconCatalog` name that is also a valid
    /// SF Symbol: the menu render path draws `iconSymbol` via `Image(systemName:)`
    /// with no catalog lookup, so a name outside both sets goes blank there.
    static let defaultIconSymbol = "heart"

    // UI constants for container forms and displays.
    // swiftlint:disable:next type_name
    enum UI {
        static let normalButtonWidth: CGFloat = 28
        static let compactButtonWidth: CGFloat = 12

        static let newContainerDialogWidth: CGFloat = 450
        static let newContainerDialogHeight: CGFloat = 380
        static let minDialogWidth: CGFloat = 450

        static let emojiButtonSize: CGFloat = 32
    }

    /// Animation constants for container interactions
    enum Animation {
        static let emojiPickerDuration: Double = 0.1
    }
}
