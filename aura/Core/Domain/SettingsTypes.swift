import Foundation

/// Per-site grants the permission prompts hand out. Stored as one JSON blob under
/// `settings.permissions.sitePermissions`, keyed by host.
struct SitePermissionSettings: Codable, Hashable, Identifiable {
    var id: String { host }

    let host: String
    var camera: Bool
    var microphone: Bool
    var location: Bool
    var notifications: Bool
}

enum AutoClearTabsAfter: String, CaseIterable, Identifiable, Codable {
    case never = "Never"
    case oneHour = "1 Hour"
    case oneDay = "1 Day"
    case oneWeek = "1 Week"

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .oneHour: return 3600
        case .oneDay: return 86400
        case .oneWeek: return 604_800
        }
    }
}

/// Where a freshly opened tab lands in the sidebar list.
enum NewTabPosition: String, CaseIterable, Identifiable, Codable {
    case top
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Top of the list"
        case .bottom: return "Bottom of the list"
        }
    }
}

/// What happens to a link handed to Aura by another app.
enum ExternalLinkTarget: String, CaseIterable, Identifiable, Codable {
    case currentSpace
    case newWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentSpace: return "The current space"
        case .newWindow: return "A new window"
        }
    }
}
