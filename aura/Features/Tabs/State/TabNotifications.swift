import Foundation

extension Notification.Name {
    /// Opens the settings page as a tab in the key window.
    /// userInfo: ["tab": SettingsTab.rawValue] preselects a section.
    static let openSettingsTab = Notification.Name("openSettingsTab")

    /// Creates a folder in the key window's active space and opens it for renaming.
    /// object: the target NSWindow, or nil for the key window.
    static let newTabFolder = Notification.Name("newTabFolder")
}
