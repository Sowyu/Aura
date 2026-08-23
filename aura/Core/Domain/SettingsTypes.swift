import Foundation

/// A capability a page can ask the browser for.
///
/// Only the media-capture kinds ever reach Aura. WebKit routes camera and microphone
/// through `WKUIDelegate`; it exposes no public delegate for geolocation or web
/// notifications, so those two are carried here (the stored blob has always had them)
/// but nothing asks for them yet.
enum SitePermissionKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case camera
    case microphone
    case location
    case notifications

    var id: String { rawValue }

    /// The kinds a prompt can actually be raised for today.
    static let promptable: [SitePermissionKind] = [.camera, .microphone]

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .location: return "Location"
        case .notifications: return "Notifications"
        }
    }

    /// Reads inside a sentence: "example.com wants to use your camera".
    var phrase: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .location: return "location"
        case .notifications: return "notifications"
        }
    }

    var symbolName: String {
        switch self {
        case .camera: return "video"
        case .microphone: return "mic"
        case .location: return "location"
        case .notifications: return "bell"
        }
    }
}

/// Per-site grants the permission prompts hand out. Stored as one JSON blob under
/// `settings.permissions.sitePermissions`, keyed by registrable domain.
///
/// Each grant is optional because "not asked yet" is a third state: a site the user gave
/// the microphone to must still be asked about the camera. Blobs written before this
/// carried plain booleans, which decode into these unchanged.
struct SitePermissionSettings: Codable, Hashable, Identifiable {
    var id: String { host }

    let host: String
    var camera: Bool?
    var microphone: Bool?
    var location: Bool?
    var notifications: Bool?

    init(
        host: String,
        camera: Bool? = nil,
        microphone: Bool? = nil,
        location: Bool? = nil,
        notifications: Bool? = nil
    ) {
        self.host = host
        self.camera = camera
        self.microphone = microphone
        self.location = location
        self.notifications = notifications
    }

    /// True to allow, false to block, nil when the site has never been answered for.
    func decision(for kind: SitePermissionKind) -> Bool? {
        switch kind {
        case .camera: return camera
        case .microphone: return microphone
        case .location: return location
        case .notifications: return notifications
        }
    }

    mutating func set(_ decision: Bool?, for kind: SitePermissionKind) {
        switch kind {
        case .camera: camera = decision
        case .microphone: microphone = decision
        case .location: location = decision
        case .notifications: notifications = decision
        }
    }

    /// Nothing is decided any more, so the host can leave the map instead of sitting
    /// there as an empty row in the settings list.
    var isEmpty: Bool {
        SitePermissionKind.allCases.allSatisfy { decision(for: $0) == nil }
    }

    /// The kinds with a stored answer, in a stable order for display.
    var decided: [(kind: SitePermissionKind, isAllowed: Bool)] {
        SitePermissionKind.allCases.compactMap { kind in
            decision(for: kind).map { (kind, $0) }
        }
    }
}

/// What the user picked in a permission prompt. `remember` is the "Remember this
/// decision" toggle; without it the answer covers this one request.
struct SitePermissionAnswer: Equatable {
    let isAllowed: Bool
    let remember: Bool
}

/// The rules that turn stored grants and a prompt answer into decisions. Pure, so the
/// awkward cases (a combined camera-and-microphone request, an allow-once) are testable
/// without a page or a window.
enum SitePermissionResolver {
    /// The stored answer for a request covering `kinds`, or nil when the user has to be
    /// asked. A request for camera and microphone together needs both: one stored block
    /// refuses it, and an allow needs every kind allowed.
    static func decision(for kinds: [SitePermissionKind], in settings: SitePermissionSettings?) -> Bool? {
        guard let settings, !kinds.isEmpty else { return nil }
        let stored = kinds.map { settings.decision(for: $0) }
        if stored.contains(false) { return false }
        return stored.allSatisfy { $0 == true } ? true : nil
    }

    /// The permission map after `answer`. An answer the user did not ask to remember is
    /// deliberately not stored: the page gets its decision and the next visit asks again.
    static func applying(
        _ answer: SitePermissionAnswer,
        kinds: [SitePermissionKind],
        host: String,
        to map: [String: SitePermissionSettings]
    ) -> [String: SitePermissionSettings] {
        guard answer.remember, !host.isEmpty, !kinds.isEmpty else { return map }
        var updated = map
        var entry = updated[host] ?? SitePermissionSettings(host: host)
        for kind in kinds {
            entry.set(answer.isAllowed, for: kind)
        }
        updated[host] = entry
        return updated
    }
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
