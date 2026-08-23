import AppKit
import Foundation

enum BrowserWebsiteDataType: Hashable {
    case cookies
    case cache
    case all
}

enum BrowserUserScriptInjectionTime {
    case atDocumentStart
    case atDocumentEnd
}

struct BrowserUserScript {
    let name: String?
    let source: String
    let injectionTime: BrowserUserScriptInjectionTime
    let forMainFrameOnly: Bool
}

struct BrowserScriptMessage {
    let name: String
    let body: Any?
}

struct BrowserOpenPanelOptions {
    let allowsDirectories: Bool
    let allowsMultipleSelection: Bool
}

/// What a page asked for. Media capture is the whole list because it is the whole list
/// WebKit routes through `WKUIDelegate`: geolocation and web notifications have no
/// public hook, so a page asking for those is answered by WebKit itself.
enum BrowserPermissionKind {
    case camera
    case microphone
    case cameraAndMicrophone
}

enum BrowserPermissionDecision {
    case grant
    case deny
    case prompt
}

struct BrowserNavigationAction {
    let request: URLRequest
    let modifierFlags: NSEvent.ModifierFlags
    /// Which mouse button started the navigation: 0 is the left one, 2 the middle one.
    var buttonNumber = 0
    /// A nil target frame means a brand-new frame or window, which counts as main frame.
    var isMainFrame = true
    /// True for a link click or a form submission, as opposed to a redirect or a reload.
    var isUserInitiated = false
}

/// Where a clicked link should land. Middle button or command opens a tab behind the
/// current one; holding shift as well brings that tab forward, as Safari and Chrome do.
enum LinkOpenIntent {
    case sameTab
    case background
    case foreground

    static func from(buttonNumber: Int, modifiers: NSEvent.ModifierFlags) -> LinkOpenIntent {
        guard buttonNumber == 2 || modifiers.contains(.command) else { return .sameTab }
        return modifiers.contains(.shift) ? .foreground : .background
    }
}

enum BrowserNavigationActionDisposition {
    case allow
    case cancel
    case openInNewTab
}

enum BrowserNavigationPhase {
    case started
    case committed
    case finished
}

struct BrowserNavigationEvent {
    let phase: BrowserNavigationPhase
    let url: URL?
    let title: String?
    let progress: Double
    let isLoading: Bool
}

struct BrowserSnapshotConfiguration {
    let rect: CGRect?
    let afterScreenUpdates: Bool
    /// Downscales the result; a rect-scoped snapshot is a known WebKit flash trigger,
    /// so callers that only need a colour take the whole view at a tiny width instead.
    var snapshotWidth: CGFloat?

    static let full = BrowserSnapshotConfiguration(rect: nil, afterScreenUpdates: false)
    /// Full view, 32 px wide, waiting for the next frame: cheap and never blanks the page.
    static let thumbnail = BrowserSnapshotConfiguration(rect: nil, afterScreenUpdates: true, snapshotWidth: 32)
}

/// What sat under the pointer when the page's context menu was asked for. Filled by the
/// page-side `contextmenu` listener, which runs before AppKit builds its own menu.
struct BrowserContextMenuInfo {
    var link: URL?
    var linkText: String?
    var image: URL?
    var media: URL?
    var selection: String?
    var isEditable = false

    var hasSelection: Bool {
        !(selection ?? "").isEmpty
    }
}
