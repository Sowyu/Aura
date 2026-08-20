import Foundation

extension Notification.Name {
    /// Opens the settings page as a tab in the key window.
    /// userInfo: ["tab": SettingsTab.rawValue] preselects a section.
    static let openSettingsTab = Notification.Name("openSettingsTab")
}
