import Foundation

extension Notification.Name {
    /// Opens Settings as a tab. Optional userInfo `["tab": String]` selects a
    /// `SettingsTab` raw value, e.g. `["tab": "extensions"]`.
    static let openSettingsTab = Notification.Name("OpenSettingsTab")
}
